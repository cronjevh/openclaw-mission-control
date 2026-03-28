"""Temporary board chat — ephemeral, not stored, proxied through OpenClaw gateway.

POST /api/v1/boards/{board_id}/temp-chat          — send a message, get reply
DELETE /api/v1/boards/{board_id}/temp-chat         — clear session history
"""

from __future__ import annotations

import json
from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse
from sqlmodel import select
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api.deps import ACTOR_DEP, SESSION_DEP, ActorContext
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.tasks import Task
from app.services.openclaw.gateway_rpc import (
    GatewayConfig,
    OpenClawGatewayError,
    openclaw_call,
    delete_session as gw_delete_session,
)
from app.services.organizations import require_board_access

router = APIRouter(prefix="/boards/{board_id}/temp-chat", tags=["temp-chat"])


def _session_key(board_id: str, user_id: str) -> str:
    """Unique ephemeral session per user per board."""
    return f"temp-chat:{board_id}:{user_id}"


async def _get_board_and_gateway(
    session: AsyncSession, board_id: UUID, actor: ActorContext
) -> tuple[Board, Gateway, GatewayConfig]:
    board = await Board.objects.by_id(board_id).first(session)
    if board is None:
        raise HTTPException(status_code=404, detail="Board not found.")

    if actor.actor_type == "user" and actor.user is not None:
        await require_board_access(session, user=actor.user, board=board, write=False)
    else:
        raise HTTPException(status_code=403)

    if board.gateway_id is None:
        raise HTTPException(status_code=503, detail="Board has no gateway configured.")

    gateway = await Gateway.objects.by_id(board.gateway_id).first(session)
    if gateway is None:
        raise HTTPException(status_code=503, detail="Gateway not found.")

    return board, gateway, GatewayConfig(url=gateway.url, token=gateway.token)


async def _build_context_block(
    session: AsyncSession,
    board: Board,
    board_id: UUID,
) -> str:
    """Build a concise board context block to prepend on first message."""

    agents_result = await session.exec(
        select(Agent).where(Agent.board_id == board_id)
    )
    agents = list(agents_result.all())

    lead = next((a for a in agents if a.is_board_lead), None)
    workers = [a for a in agents if not a.is_board_lead]

    tasks_result = await session.exec(
        select(Task)
        .where(Task.board_id == board_id)
        .order_by(Task.updated_at.desc())  # type: ignore[attr-defined]
        .limit(60)
    )
    tasks = list(tasks_result.all())

    def fmt(lst: list[Task], limit: int = 6) -> str:
        if not lst:
            return "  (none)"
        lines = []
        for t in lst[:limit]:
            assignee = next(
                (a.name for a in agents if str(a.id) == str(t.assigned_agent_id)),
                "unassigned",
            )
            lines.append(f"  • [{t.id[:8]}] {t.title} → {assignee}")
        if len(lst) > limit:
            lines.append(f"  … +{len(lst) - limit} more")
        return "\n".join(lines)

    agent_lines = []
    if lead:
        agent_lines.append(f"  • {lead.name} (lead, {lead.status})")
    for w in workers:
        agent_lines.append(f"  • {w.name} (worker, {w.status})")

    by_status = {
        "in_progress": [t for t in tasks if t.status == "in_progress"],
        "review":      [t for t in tasks if t.status == "review"],
        "inbox":       [t for t in tasks if t.status == "inbox"],
        "blocked":     [t for t in tasks if t.status == "blocked"],
    }

    return f"""<board_context>
Board: {board.name}

Agents:
{chr(10).join(agent_lines) if agent_lines else "  (none)"}

In Progress ({len(by_status["in_progress"])}):
{fmt(by_status["in_progress"])}

In Review ({len(by_status["review"])}):
{fmt(by_status["review"])}

Inbox ({len(by_status["inbox"])}):
{fmt(by_status["inbox"])}

Blocked ({len(by_status["blocked"])}):
{fmt(by_status["blocked"])}
</board_context>

You are a helpful assistant embedded in Mission Control. Answer questions about this board using the context above.
This is a temporary private chat — messages are NOT stored and NOT visible to board agents.
Be concise and direct. Now answer the user's question:"""


@router.post("")
async def send_temp_chat(
    board_id: str,
    request: Request,
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> StreamingResponse:
    """Send a message and stream the AI reply as SSE."""
    board_uuid = _parse_uuid(board_id)
    board, gateway, config = await _get_board_and_gateway(session, board_uuid, actor)

    body = await request.json()
    message: str = (body.get("message") or "").strip()
    is_first: bool = bool(body.get("is_first", False))
    if not message:
        raise HTTPException(status_code=422, detail="message is required.")

    user_id = str(actor.user.id) if actor.user else "anon"
    session_key = _session_key(board_id, user_id)

    # On first message, prepend board context so the model knows the board state
    if is_first:
        context = await _build_context_block(session, board, board_uuid)
        full_message = f"{context}\n\n{message}"
        # Reset session so history doesn't bleed across reloads
        try:
            await gw_delete_session(session_key, config=config)
        except OpenClawGatewayError:
            pass
    else:
        full_message = message

    async def event_stream():
        try:
            result = await openclaw_call(
                "chat.send",
                {
                    "sessionKey": session_key,
                    "message": full_message,
                    "deliver": False,
                    "idempotencyKey": str(uuid4()),
                },
                config=config,
            )

            if isinstance(result, dict):
                text = (
                    result.get("text")
                    or result.get("content")
                    or result.get("message")
                    or str(result)
                )
            else:
                text = str(result) if result else ""

            yield f"data: {json.dumps({'text': text, 'done': True})}\n\n"

        except OpenClawGatewayError as exc:
            yield f"data: {json.dumps({'error': str(exc), 'done': True})}\n\n"
        except Exception:  # noqa: BLE001
            yield f"data: {json.dumps({'error': 'Unexpected error. Please try again.', 'done': True})}\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.delete("")
async def clear_temp_chat(
    board_id: str,
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> dict:
    """Delete the ephemeral session (clear history)."""
    board_uuid = _parse_uuid(board_id)
    board, gateway, config = await _get_board_and_gateway(session, board_uuid, actor)

    user_id = str(actor.user.id) if actor.user else "anon"
    try:
        await gw_delete_session(_session_key(board_id, user_id), config=config)
    except OpenClawGatewayError:
        pass
    return {"ok": True}


def _parse_uuid(value: str) -> UUID:
    try:
        return UUID(value)
    except ValueError:
        raise HTTPException(status_code=422, detail="Invalid id.")


# ---------------------------------------------------------------------------
# Board-group temp chat
# ---------------------------------------------------------------------------

group_router = APIRouter(prefix="/board-groups/{group_id}/temp-chat", tags=["temp-chat"])


def _group_session_key(group_id: str, user_id: str) -> str:
    return f"temp-chat:group:{group_id}:{user_id}"


async def _get_group_and_gateway(
    session: AsyncSession, group_id: UUID, actor: ActorContext
) -> tuple[object, Gateway, GatewayConfig]:
    from app.models.board_groups import BoardGroup
    from app.services.organizations import get_active_membership

    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None:
        raise HTTPException(status_code=404, detail="Board group not found.")

    if actor.actor_type != "user" or actor.user is None:
        raise HTTPException(status_code=403)

    member = await get_active_membership(session, actor.user)
    if member is None or member.organization_id != group.organization_id:
        raise HTTPException(status_code=403)

    # Resolve gateway via group agent
    if group.group_agent_id is None:
        raise HTTPException(status_code=503, detail="Group has no agent configured.")

    group_agent = await Agent.objects.by_id(group.group_agent_id).first(session)
    if group_agent is None or group_agent.gateway_id is None:
        raise HTTPException(status_code=503, detail="Group agent has no gateway.")

    gateway = await Gateway.objects.by_id(group_agent.gateway_id).first(session)
    if gateway is None:
        raise HTTPException(status_code=503, detail="Gateway not found.")

    return group, gateway, GatewayConfig(url=gateway.url, token=gateway.token)


async def _build_group_context_block(
    session: AsyncSession,
    group: object,
    group_id: UUID,
) -> str:
    from app.models.board_groups import BoardGroup
    from app.models.boards import Board as BoardModel

    boards_result = await session.exec(
        select(BoardModel).where(BoardModel.board_group_id == group_id)
    )
    boards = list(boards_result.all())

    tasks_result = await session.exec(
        select(Task)
        .where(Task.board_group_id == group_id)
        .order_by(Task.updated_at.desc())  # type: ignore[attr-defined]
        .limit(40)
    )
    group_tasks = list(tasks_result.all())

    def fmt(lst: list[Task], limit: int = 5) -> str:
        if not lst:
            return "  (none)"
        lines = [f"  • [{t.id[:8]}] {t.title}" for t in lst[:limit]]
        if len(lst) > limit:
            lines.append(f"  … +{len(lst) - limit} more")
        return "\n".join(lines)

    by_status = {s: [t for t in group_tasks if t.status == s]
                 for s in ("in_progress", "review", "inbox", "blocked")}

    board_lines = "\n".join(f"  • {b.name} ({b.id})" for b in boards) or "  (none)"
    group_name = getattr(group, "name", str(group_id))

    return f"""<group_context>
Group: {group_name}

Linked boards ({len(boards)}):
{board_lines}

Group Tasks — In Progress ({len(by_status["in_progress"])}):
{fmt(by_status["in_progress"])}

Group Tasks — In Review ({len(by_status["review"])}):
{fmt(by_status["review"])}

Group Tasks — Inbox ({len(by_status["inbox"])}):
{fmt(by_status["inbox"])}

Group Tasks — Blocked ({len(by_status["blocked"])}):
{fmt(by_status["blocked"])}
</group_context>

You are a helpful assistant embedded in Mission Control. Answer questions about this board group using the context above.
This is a temporary private chat — not stored, not visible to agents.
Be concise and direct. Now answer the user's question:"""


@group_router.post("")
async def send_group_temp_chat(
    group_id: str,
    request: Request,
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> StreamingResponse:
    group_uuid = _parse_uuid(group_id)
    group, gateway, config = await _get_group_and_gateway(session, group_uuid, actor)

    body = await request.json()
    message: str = (body.get("message") or "").strip()
    is_first: bool = bool(body.get("is_first", False))
    if not message:
        raise HTTPException(status_code=422, detail="message is required.")

    user_id = str(actor.user.id) if actor.user else "anon"
    session_key = _group_session_key(group_id, user_id)

    if is_first:
        context = await _build_group_context_block(session, group, group_uuid)
        full_message = f"{context}\n\n{message}"
        try:
            await gw_delete_session(session_key, config=config)
        except OpenClawGatewayError:
            pass
    else:
        full_message = message

    async def event_stream():
        try:
            result = await openclaw_call(
                "chat.send",
                {
                    "sessionKey": session_key,
                    "message": full_message,
                    "deliver": False,
                    "idempotencyKey": str(uuid4()),
                },
                config=config,
            )
            if isinstance(result, dict):
                text = result.get("text") or result.get("content") or result.get("message") or str(result)
            else:
                text = str(result) if result else ""
            yield f"data: {json.dumps({'text': text, 'done': True})}\n\n"
        except OpenClawGatewayError as exc:
            yield f"data: {json.dumps({'error': str(exc), 'done': True})}\n\n"
        except Exception:  # noqa: BLE001
            yield f"data: {json.dumps({'error': 'Unexpected error. Please try again.', 'done': True})}\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@group_router.delete("")
async def clear_group_temp_chat(
    group_id: str,
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> dict:
    group_uuid = _parse_uuid(group_id)
    group, gateway, config = await _get_group_and_gateway(session, group_uuid, actor)
    user_id = str(actor.user.id) if actor.user else "anon"
    try:
        await gw_delete_session(_group_session_key(group_id, user_id), config=config)
    except OpenClawGatewayError:
        pass
    return {"ok": True}
