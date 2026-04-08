"""Board memory CRUD and streaming endpoints."""

from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime
from typing import TYPE_CHECKING
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy import func
from sqlmodel import col
from sse_starlette.sse import EventSourceResponse

from app.api.deps import (
    ActorContext,
    get_board_for_actor_read,
    get_board_for_actor_write,
    require_user_or_agent,
)
from app.core.config import settings
from app.core.time import utcnow
from app.db.pagination import paginate
from app.db.session import async_session_maker, get_session
from app.models.agents import Agent
from app.models.board_memory import BoardMemory
from app.schemas.board_memory import BoardMemoryCreate, BoardMemoryRead
from app.schemas.pagination import DefaultLimitOffsetPage
from app.services.mentions import extract_mentions, matches_agent_mention
from app.services.openclaw.gateway_dispatch import GatewayDispatchService
from app.services.openclaw.gateway_rpc import (
    GatewayConfig as GatewayClientConfig,
    OpenClawGatewayError,
    openclaw_call,
)

if TYPE_CHECKING:
    from collections.abc import AsyncIterator

    from fastapi_pagination.limit_offset import LimitOffsetPage
    from sqlmodel.ext.asyncio.session import AsyncSession

    from app.models.boards import Board

router = APIRouter(prefix="/boards/{board_id}/memory", tags=["board-memory"])
MAX_SNIPPET_LENGTH = 800
STREAM_POLL_SECONDS = 2
SESSION_REPLY_POLL_SECONDS = 2
SESSION_REPLY_TIMEOUT_SECONDS = 45
IS_CHAT_QUERY = Query(default=None)
SINCE_QUERY = Query(default=None)
TASK_ID_QUERY = Query(default=None)
BOARD_READ_DEP = Depends(get_board_for_actor_read)
BOARD_WRITE_DEP = Depends(get_board_for_actor_write)
SESSION_DEP = Depends(get_session)
ACTOR_DEP = Depends(require_user_or_agent)
_RUNTIME_TYPE_REFERENCES = (UUID,)


def _parse_since(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.strip()
    if not normalized:
        return None
    normalized = normalized.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is not None:
        return parsed.astimezone(UTC).replace(tzinfo=None)
    return parsed


def _serialize_memory(memory: BoardMemory) -> dict[str, object]:
    return BoardMemoryRead.model_validate(
        memory,
        from_attributes=True,
    ).model_dump(mode="json")


def _board_reply_guidance() -> str:
    return (
        "Reply in plain natural language as a concise board-chat message.\n"
        "Do not output shell commands, curl snippets, JSON payloads, or code blocks.\n"
        "If asked a simple question, answer it directly in one short sentence.\n"
        "Do not promise future actions or outcomes unless they are already completed and verified.\n"
        "If something is blocked, state the concrete blocker instead of making a promise."
    )


def _extract_text_from_session_message(msg: dict[str, object]) -> str:
    content = msg.get("content", "")
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text")
                if isinstance(text, str) and text.strip():
                    parts.append(text)
        return "\n".join(parts).strip()
    return str(content).strip()


def _normalize_session_reply_text(text: str) -> str:
    normalized = text.strip()
    if normalized.startswith("[[reply_to_current]]"):
        normalized = normalized[len("[[reply_to_current]]") :].strip()
    return normalized


def _looks_like_command_payload(text: str) -> bool:
    normalized = text.strip().lower()
    if not normalized:
        return True
    command_markers = (
        "reply_text=$(cat <<'eof'",
        "auth_token=$(grep '^auth_token='",
        "curl -fss -x post",
        "curl -fss -xpost",
        "x-agent-token:",
        "--data-binary @-",
        "jq -n --arg content",
    )
    return any(marker in normalized for marker in command_markers)


def _looks_like_unverified_promise(text: str) -> bool:
    normalized = text.strip().lower()
    if not normalized:
        return False
    promise_markers = (
        "i will ",
        "i'll ",
        "we will ",
        "we'll ",
        "going to ",
        "let me ",
        "asap",
        "soon",
        "in a bit",
        "once i ",
    )
    completion_markers = (
        "already ",
        "done",
        "completed",
        "fixed",
        "resolved",
        "posted",
        "updated",
        "created",
        "assigned",
        "unblocked",
        "blocked by ",
    )
    has_promise = any(marker in normalized for marker in promise_markers)
    if not has_promise:
        return False
    return not any(marker in normalized for marker in completion_markers)


def _message_seq(msg: dict[str, object]) -> int | None:
    seq = (msg.get("__openclaw") or {}).get("seq")
    if not isinstance(seq, (int, float)):
        return None
    return int(seq)


def _find_matching_user_seq(
    messages: list[dict[str, object]],
    *,
    after_seq: int,
    expected_message: str,
) -> int | None:
    expected = expected_message.strip()
    if not expected:
        return None
    for msg in messages:
        seq = _message_seq(msg)
        if seq is None or seq <= after_seq:
            continue
        if msg.get("role") != "user":
            continue
        text = _extract_text_from_session_message(msg).strip()
        if text == expected:
            return seq
    return None


def _max_seq_from_history(payload: object) -> int:
    if not isinstance(payload, dict):
        return 0
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return 0
    max_seq = 0
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        seq = (msg.get("__openclaw") or {}).get("seq")
        if isinstance(seq, (int, float)) and int(seq) > max_seq:
            max_seq = int(seq)
    return max_seq


async def _baseline_session_seq(
    *,
    session_key: str,
    config: GatewayClientConfig,
) -> int:
    try:
        payload = await openclaw_call(
            "chat.history",
            {"sessionKey": session_key, "limit": 8},
            config=config,
        )
    except OpenClawGatewayError:
        return 0
    return _max_seq_from_history(payload)


async def _mirror_session_reply_to_board_chat(
    *,
    board_id: UUID,
    agent_name: str,
    session_key: str,
    config: GatewayClientConfig,
    after_seq: int,
    expected_message: str,
) -> None:
    resolved_user_seq: int | None = None
    deadline = asyncio.get_running_loop().time() + SESSION_REPLY_TIMEOUT_SECONDS
    while asyncio.get_running_loop().time() < deadline:
        try:
            payload = await openclaw_call(
                "chat.history",
                {"sessionKey": session_key, "limit": 24},
                config=config,
            )
        except OpenClawGatewayError:
            await asyncio.sleep(SESSION_REPLY_POLL_SECONDS)
            continue

        messages = payload.get("messages") if isinstance(payload, dict) else None
        if not isinstance(messages, list):
            await asyncio.sleep(SESSION_REPLY_POLL_SECONDS)
            continue

        typed_messages = [msg for msg in messages if isinstance(msg, dict)]
        if resolved_user_seq is None:
            resolved_user_seq = _find_matching_user_seq(
                typed_messages,
                after_seq=after_seq,
                expected_message=expected_message,
            )
        anchor_seq = resolved_user_seq if resolved_user_seq is not None else after_seq

        reply_text = ""
        for msg in reversed(typed_messages):
            seq = _message_seq(msg)
            if seq is None or seq <= anchor_seq:
                continue
            if msg.get("role") != "assistant":
                continue
            candidate = _normalize_session_reply_text(_extract_text_from_session_message(msg))
            if not candidate:
                continue
            if candidate.strip().upper() == "NO_REPLY":
                continue
            if _looks_like_unverified_promise(candidate):
                continue
            if not _looks_like_command_payload(candidate):
                reply_text = candidate
                break

        if reply_text:
            async with async_session_maker() as mirror_session:
                recent = (
                    BoardMemory.objects.filter_by(board_id=board_id, source=agent_name, is_chat=True)
                    .order_by(col(BoardMemory.created_at).desc())
                    .limit(3)
                )
                recent_rows = await recent.all(mirror_session)
                if any((row.content or "").strip() == reply_text for row in recent_rows):
                    return
                mirror_session.add(
                    BoardMemory(
                        board_id=board_id,
                        content=reply_text,
                        tags=["chat"],
                        is_chat=True,
                        source=agent_name,
                    ),
                )
                await mirror_session.commit()
            return

        await asyncio.sleep(SESSION_REPLY_POLL_SECONDS)


async def _fetch_memory_events(
    session: AsyncSession,
    board_id: UUID,
    since: datetime,
    is_chat: bool | None = None,
) -> list[BoardMemory]:
    statement = (
        BoardMemory.objects.filter_by(board_id=board_id)
        # Old/invalid rows (empty/whitespace-only content) can exist; exclude them to
        # satisfy the NonEmptyStr response schema.
        .filter(func.length(func.trim(col(BoardMemory.content))) > 0)
    )
    if is_chat is not None:
        statement = statement.filter(col(BoardMemory.is_chat) == is_chat)
    statement = statement.filter(col(BoardMemory.created_at) >= since).order_by(
        col(BoardMemory.created_at),
    )
    return await statement.all(session)


async def _send_control_command(
    *,
    session: AsyncSession,
    board: Board,
    actor: ActorContext,
    dispatch: GatewayDispatchService,
    config: GatewayClientConfig,
    command: str,
) -> None:
    pause_targets: list[Agent] = await Agent.objects.filter_by(
        board_id=board.id,
    ).all(
        session,
    )
    for agent in pause_targets:
        if actor.actor_type == "agent" and actor.agent and agent.id == actor.agent.id:
            continue
        if not agent.openclaw_session_id:
            continue
        error = await dispatch.try_send_agent_message(
            session_key=agent.openclaw_session_id,
            config=config,
            agent_name=agent.name,
            message=command,
            deliver=True,
            agent=agent,
            board=board,
        )
        if error is not None:
            continue


def _chat_targets(
    *,
    agents: list[Agent],
    mentions: set[str],
    actor: ActorContext,
) -> dict[str, Agent]:
    targets: dict[str, Agent] = {}
    for agent in agents:
        if agent.is_board_lead:
            targets[str(agent.id)] = agent
            continue
        if mentions and matches_agent_mention(agent, mentions):
            targets[str(agent.id)] = agent
    if actor.actor_type == "agent" and actor.agent:
        targets.pop(str(actor.agent.id), None)
    return targets


def _actor_display_name(actor: ActorContext) -> str:
    if actor.actor_type == "agent" and actor.agent:
        return actor.agent.name
    if actor.user:
        return actor.user.name or "User"
    return "User"


async def _notify_chat_targets(
    *,
    session: AsyncSession,
    board: Board,
    memory: BoardMemory,
    actor: ActorContext,
) -> None:
    if not memory.content:
        return
    dispatch = GatewayDispatchService(session)
    config = await dispatch.optional_gateway_config_for_board(board)
    if config is None:
        return

    normalized = memory.content.strip()
    command = normalized.lower()
    # Special-case control commands to reach all board agents.
    # These are intended to be parsed verbatim by agent runtimes.
    if command in {"/pause", "/resume", "/new"}:
        await _send_control_command(
            session=session,
            board=board,
            actor=actor,
            dispatch=dispatch,
            config=config,
            command=command,
        )
        return

    mentions = extract_mentions(memory.content)
    targets = _chat_targets(
        agents=await Agent.objects.filter_by(board_id=board.id).all(session),
        mentions=mentions,
        actor=actor,
    )
    if not targets:
        return
    actor_name = _actor_display_name(actor)
    snippet = memory.content.strip()
    if len(snippet) > MAX_SNIPPET_LENGTH:
        snippet = f"{snippet[: MAX_SNIPPET_LENGTH - 3]}..."
    base_url = settings.base_url
    for agent in targets.values():
        if not agent.openclaw_session_id:
            continue
        baseline_seq = await _baseline_session_seq(
            session_key=agent.openclaw_session_id,
            config=config,
        )
        mentioned = matches_agent_mention(agent, mentions)
        header = "BOARD CHAT MENTION" if mentioned else "BOARD CHAT"
        message = (
            f"{header}\n"
            f"Board: {board.name}\n"
            f"From: {actor_name}\n\n"
            f"{snippet}\n\n"
            f"{_board_reply_guidance()}"
        )
        error = await dispatch.try_send_agent_message(
            session_key=agent.openclaw_session_id,
            config=config,
            agent_name=agent.name,
            message=message,
            deliver=True,
            agent=agent,
            board=board,
        )
        if error is not None:
            continue
        # Fallback mirror path: if the agent answers in session chat but fails
        # to execute the board-memory POST, persist that reply into board chat.
        asyncio.create_task(
            _mirror_session_reply_to_board_chat(
                board_id=board.id,
                agent_name=agent.name,
                session_key=agent.openclaw_session_id,
                config=config,
                after_seq=baseline_seq,
                expected_message=message,
            ),
        )


@router.get("", response_model=DefaultLimitOffsetPage[BoardMemoryRead])
async def list_board_memory(
    *,
    is_chat: bool | None = IS_CHAT_QUERY,
    task_id: UUID | None = TASK_ID_QUERY,
    board: Board = BOARD_READ_DEP,
    session: AsyncSession = SESSION_DEP,
    _actor: ActorContext = ACTOR_DEP,
) -> LimitOffsetPage[BoardMemoryRead]:
    """List board memory entries, optionally filtering by chat flag or task."""
    statement = (
        BoardMemory.objects.filter_by(board_id=board.id)
        # Old/invalid rows (empty/whitespace-only content) can exist; exclude them to
        # satisfy the NonEmptyStr response schema.
        .filter(func.length(func.trim(col(BoardMemory.content))) > 0)
    )
    if is_chat is not None:
        statement = statement.filter(col(BoardMemory.is_chat) == is_chat)
    if task_id is not None:
        statement = statement.filter(col(BoardMemory.task_id) == task_id)
    statement = statement.order_by(col(BoardMemory.created_at).desc())
    return await paginate(session, statement.statement)


@router.get("/stream")
async def stream_board_memory(
    request: Request,
    *,
    board: Board = BOARD_READ_DEP,
    _actor: ActorContext = ACTOR_DEP,
    since: str | None = SINCE_QUERY,
    is_chat: bool | None = IS_CHAT_QUERY,
) -> EventSourceResponse:
    """Stream board memory events over server-sent events."""
    since_dt = _parse_since(since) or utcnow()
    last_seen = since_dt

    async def event_generator() -> AsyncIterator[dict[str, str]]:
        nonlocal last_seen
        while True:
            if await request.is_disconnected():
                break
            async with async_session_maker() as session:
                memories = await _fetch_memory_events(
                    session,
                    board.id,
                    last_seen,
                    is_chat=is_chat,
                )
            for memory in memories:
                last_seen = max(memory.created_at, last_seen)
                payload = {"memory": _serialize_memory(memory)}
                yield {"event": "memory", "data": json.dumps(payload)}
            await asyncio.sleep(STREAM_POLL_SECONDS)

    return EventSourceResponse(event_generator(), ping=15)


@router.post("", response_model=BoardMemoryRead)
async def create_board_memory(
    payload: BoardMemoryCreate,
    board: Board = BOARD_WRITE_DEP,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> BoardMemory:
    """Create a board memory entry and notify chat targets when needed."""
    is_chat = payload.tags is not None and "chat" in payload.tags
    # For chat messages always derive source from the authenticated actor — never
    # trust the client-provided value (prevents display-name spoofing).
    if is_chat:
        if actor.actor_type == "agent" and actor.agent:
            source = actor.agent.name
        elif actor.user:
            source = actor.user.name or "User"
        else:
            source = payload.source
    else:
        source = payload.source
    memory = BoardMemory(
        board_id=board.id,
        content=payload.content,
        tags=payload.tags,
        is_chat=is_chat,
        source=source,
    )
    session.add(memory)
    await session.commit()
    await session.refresh(memory)
    if is_chat:
        await _notify_chat_targets(
            session=session,
            board=board,
            memory=memory,
            actor=actor,
        )
    return memory
