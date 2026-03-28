"""Temporary board / board-group chat.

Works exactly like the regular board chat (messages go to the lead agent's
real session) but skips the DB write — nothing is stored, nothing shows in
board memory or live feed.

POST   /api/v1/boards/{board_id}/temp-chat        — send, wait, return reply
DELETE /api/v1/boards/{board_id}/temp-chat         — (no-op, stateless from our side)

POST   /api/v1/board-groups/{group_id}/temp-chat
DELETE /api/v1/board-groups/{group_id}/temp-chat
"""

from __future__ import annotations

from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, Request
from sqlmodel import select
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api.deps import ACTOR_DEP, SESSION_DEP, ActorContext
from app.core.config import settings
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.services.openclaw.gateway_dispatch import GatewayDispatchService
from app.services.openclaw.gateway_rpc import (
    GatewayConfig,
    OpenClawGatewayError,
    openclaw_call,
)
from app.services.organizations import require_board_access

router = APIRouter(prefix="/boards/{board_id}/temp-chat", tags=["temp-chat"])
group_router = APIRouter(prefix="/board-groups/{group_id}/temp-chat", tags=["temp-chat"])

_WAIT_TIMEOUT_MS = 60_000


def _actor_name(actor: ActorContext) -> str:
    if actor.user:
        return actor.user.name or "User"
    return "User"


def _extract_text_from_msg(msg: dict) -> str:
    """Extract plain text from an assistant message dict."""
    content = msg.get("content", "")
    if isinstance(content, list):
        parts = [
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        return "\n".join(parts).strip()
    return str(content).strip()


def _extract_reply(history: object) -> str:
    """Pull the last assistant text from a chat.history response."""
    if not isinstance(history, dict):
        return ""
    messages = history.get("messages") or []
    if not isinstance(messages, list):
        return ""
    for msg in reversed(messages):
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "assistant":
            continue
        text = _extract_text_from_msg(msg)
        if text:
            return text
    return ""


def _extract_reply_after(history: object, after_ts_ms: int) -> str:
    """Pull the last assistant text that arrived after `after_ts_ms`."""
    if not isinstance(history, dict):
        return ""
    messages = history.get("messages") or []
    if not isinstance(messages, list):
        return ""
    for msg in reversed(messages):
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "assistant":
            continue
        ts = msg.get("timestamp", 0)
        if isinstance(ts, (int, float)) and ts < after_ts_ms:
            # This message is older than our send — stop looking
            break
        text = _extract_text_from_msg(msg)
        if text:
            return text
    return ""


async def _send_and_wait(
    *,
    session_key: str,
    message: str,
    config: GatewayConfig,
) -> str:
    """Send a message to an agent session and wait for the reply.

    agent.wait only signals when the *current* run finishes, but the lead
    may do multiple tool-use turns before giving a final text reply. We poll
    chat.history until we see a new assistant text message that appeared after
    our user message, or until we hit the overall timeout.
    """
    import asyncio
    import time

    run_id = str(uuid4())
    sent_at = time.monotonic()

    await openclaw_call(
        "chat.send",
        {
            "sessionKey": session_key,
            "message": message,
            "deliver": False,
            "idempotencyKey": run_id,
        },
        config=config,
    )

    # Record the timestamp of the user message we just sent so we only
    # accept assistant replies that come *after* it.
    sent_ts = int(time.time() * 1000)

    deadline = sent_at + _WAIT_TIMEOUT_MS / 1000

    while time.monotonic() < deadline:
        # Wait for the current agent run to finish
        remaining_ms = max(1000, int((deadline - time.monotonic()) * 1000))
        wait_result = await openclaw_call(
            "agent.wait",
            {"runId": run_id, "timeoutMs": min(remaining_ms, 30_000)},
            config=config,
        )

        # Fetch history and look for a final text reply after our message
        history = await openclaw_call(
            "chat.history",
            {"sessionKey": session_key, "limit": 10},
            config=config,
        )
        text = _extract_reply_after(history, sent_ts)
        if text:
            return text

        # If the agent is still running more tool-use turns, wait a bit
        # and get the next run's completion signal
        if wait_result.get("status") in ("ok", "timeout"):
            # Try once more with a fresh wait for any follow-up turns
            await asyncio.sleep(1)
            history = await openclaw_call(
                "chat.history",
                {"sessionKey": session_key, "limit": 10},
                config=config,
            )
            text = _extract_reply_after(history, sent_ts)
            if text:
                return text
            # No more turns expected - break out
            break

    # Last attempt
    history = await openclaw_call(
        "chat.history",
        {"sessionKey": session_key, "limit": 10},
        config=config,
    )
    return _extract_reply_after(history, sent_ts) or _extract_reply(history)


# ---------------------------------------------------------------------------
# Board temp chat
# ---------------------------------------------------------------------------

async def _board_lead_and_config(
    session: AsyncSession, board_id: UUID, actor: ActorContext
) -> tuple[Board, Agent, GatewayConfig]:
    board = await Board.objects.by_id(board_id).first(session)
    if board is None:
        raise HTTPException(status_code=404, detail="Board not found.")
    if actor.actor_type == "user" and actor.user is not None:
        await require_board_access(session, user=actor.user, board=board, write=False)
    else:
        raise HTTPException(status_code=403)

    agents = await Agent.objects.filter_by(board_id=board_id).all(session)
    lead = next((a for a in agents if a.is_board_lead), None)
    if lead is None or not lead.openclaw_session_id:
        raise HTTPException(status_code=503, detail="Board has no lead agent.")
    if board.gateway_id is None:
        raise HTTPException(status_code=503, detail="Board has no gateway configured.")
    gateway = await Gateway.objects.by_id(board.gateway_id).first(session)
    if gateway is None:
        raise HTTPException(status_code=503, detail="Gateway not found.")
    return board, lead, GatewayConfig(url=gateway.url, token=gateway.token)


@router.post("")
async def send_board_temp_chat(
    board_id: str,
    request: Request,
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> dict:
    board_uuid = _parse_uuid(board_id)
    board, lead, config = await _board_lead_and_config(session, board_uuid, actor)

    body = await request.json()
    message: str = (body.get("message") or "").strip()
    if not message:
        raise HTTPException(status_code=422, detail="message is required.")

    actor_name = _actor_name(actor)
    # Format exactly like board chat so the lead responds naturally,
    # but include a note that this is temp (not stored, no reply needed via API)
    formatted = (
        f"BOARD CHAT (temporary — do NOT reply via the board memory API, "
        f"just respond directly in this conversation)\n"
        f"Board: {board.name}\n"
        f"From: {actor_name}\n\n"
        f"{message}"
    )

    try:
        # Wake the lead if offline (same as regular board chat)
        dispatch = GatewayDispatchService(session)
        await dispatch.wake_agent_if_offline(agent=lead, board=board)

        reply = await _send_and_wait(
            session_key=lead.openclaw_session_id,
            message=formatted,
            config=config,
        )
        return {"text": reply or "(No response from the lead agent. The agent may be busy — try again.)"}
    except OpenClawGatewayError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception:  # noqa: BLE001
        raise HTTPException(status_code=500, detail="Unexpected error. Please try again.")


@router.delete("")
async def clear_board_temp_chat(board_id: str) -> dict:
    # Nothing to clear — messages live in the lead's normal session history
    # but don't affect board memory. No-op from our side.
    return {"ok": True}


# ---------------------------------------------------------------------------
# Board-group temp chat
# ---------------------------------------------------------------------------

async def _group_lead_and_config(
    session: AsyncSession, group_id: UUID, actor: ActorContext
) -> tuple[object, Agent, GatewayConfig]:
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

    if group.group_agent_id is None:
        raise HTTPException(status_code=503, detail="Group has no agent configured.")
    group_agent = await Agent.objects.by_id(group.group_agent_id).first(session)
    if group_agent is None or not group_agent.openclaw_session_id:
        raise HTTPException(status_code=503, detail="Group agent not available.")
    if group_agent.gateway_id is None:
        raise HTTPException(status_code=503, detail="Group agent has no gateway.")
    gateway = await Gateway.objects.by_id(group_agent.gateway_id).first(session)
    if gateway is None:
        raise HTTPException(status_code=503, detail="Gateway not found.")
    return group, group_agent, GatewayConfig(url=gateway.url, token=gateway.token)


@group_router.post("")
async def send_group_temp_chat(
    group_id: str,
    request: Request,
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> dict:
    group_uuid = _parse_uuid(group_id)
    group, group_agent, config = await _group_lead_and_config(session, group_uuid, actor)

    body = await request.json()
    message: str = (body.get("message") or "").strip()
    if not message:
        raise HTTPException(status_code=422, detail="message is required.")

    actor_name = _actor_name(actor)
    group_name = getattr(group, "name", str(group_id))
    formatted = (
        f"GROUP CHAT (temporary — do NOT reply via the board-group memory API, "
        f"just respond directly in this conversation)\n"
        f"Group: {group_name}\n"
        f"From: {actor_name}\n\n"
        f"{message}"
    )

    try:
        dispatch = GatewayDispatchService(session)
        await dispatch.wake_agent_if_offline(agent=group_agent, board=None)

        reply = await _send_and_wait(
            session_key=group_agent.openclaw_session_id,
            message=formatted,
            config=config,
        )
        return {"text": reply or "(No response from the group agent. The agent may be busy — try again.)"}
    except OpenClawGatewayError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception:  # noqa: BLE001
        raise HTTPException(status_code=500, detail="Unexpected error. Please try again.")


@group_router.delete("")
async def clear_group_temp_chat(group_id: str) -> dict:
    return {"ok": True}


def _parse_uuid(value: str) -> UUID:
    try:
        return UUID(value)
    except ValueError:
        raise HTTPException(status_code=422, detail="Invalid id.")
