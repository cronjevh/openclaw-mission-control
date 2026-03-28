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
_OFFLINE_THRESHOLD_SECONDS = 600  # 10 minutes


async def _ensure_agent_ready(
    session: AsyncSession,
    *,
    agent: Agent,
    board: Board | None,
) -> None:
    """Make sure the agent is online with a valid token before sending.

    Handles all common broken states:
    - status stuck in 'updating'/'offline'/'provisioning'
    - stale token (last_seen_at > 10 min ago)
    - wake_attempts exhausted

    This is more aggressive than the regular chat's wake_agent_if_offline:
    it resets the agent state, regenerates the token if needed, and runs
    a full lifecycle update.
    """
    from datetime import datetime, timezone, timedelta
    from app.core.time import utcnow
    from app.core.agent_tokens import generate_agent_token, hash_agent_token

    now = datetime.now(timezone.utc)
    last_seen = agent.last_seen_at
    is_stale = (
        last_seen is None
        or (now - last_seen.replace(tzinfo=timezone.utc) if last_seen.tzinfo is None else now - last_seen).total_seconds() > _OFFLINE_THRESHOLD_SECONDS
    )
    is_stuck = agent.status in ("updating", "offline", "provisioning")

    if not is_stale and not is_stuck:
        return  # Agent looks healthy

    from app.core.logging import get_logger
    logger = get_logger(__name__)
    logger.info(
        "temp_chat.ensure_agent_ready",
        extra={
            "agent_name": agent.name,
            "agent_id": str(agent.id),
            "status": agent.status,
            "is_stale": is_stale,
            "is_stuck": is_stuck,
        },
    )

    # Reset stuck state
    agent.status = "online"
    agent.provision_action = None
    agent.last_provision_error = None
    agent.wake_attempts = 0
    agent.checkin_deadline_at = None
    agent.updated_at = utcnow()

    # Regenerate token and sync to DB
    new_token = generate_agent_token()
    agent.agent_token_hash = hash_agent_token(new_token)
    session.add(agent)
    await session.flush()

    # Write token to TOOLS.md on host filesystem
    _write_token_to_tools(agent, new_token)

    # Run full lifecycle to wake the agent
    try:
        from app.models.gateways import Gateway as GatewayModel
        from app.services.openclaw.lifecycle_orchestrator import AgentLifecycleOrchestrator

        gateway = await GatewayModel.objects.by_id(agent.gateway_id).first(session)
        if gateway is None:
            await session.commit()
            return

        resolved_board = board
        if resolved_board is None and agent.board_id is not None:
            resolved_board = await Board.objects.by_id(agent.board_id).first(session)

        await session.commit()

        orchestrator = AgentLifecycleOrchestrator(session)
        await orchestrator.run_lifecycle(
            gateway=gateway,
            agent_id=agent.id,
            board=resolved_board,
            user=None,
            action="update",
            wake=True,
            deliver_wakeup=True,
            raise_gateway_errors=False,
        )

        # Tell the agent to re-read TOOLS.md so it picks up the new token
        if agent.openclaw_session_id and gateway:
            try:
                config = GatewayConfig(url=gateway.url, token=gateway.token)
                await openclaw_call(
                    "chat.send",
                    {
                        "sessionKey": agent.openclaw_session_id,
                        "message": (
                            "SYSTEM: Your AUTH_TOKEN was just refreshed. "
                            "Re-read your TOOLS.md file NOW to pick up the new token. "
                            "The old token is invalid (401). Do this before any API calls."
                        ),
                        "deliver": False,
                        "idempotencyKey": str(uuid4()),
                    },
                    config=config,
                )
                # Wait for the agent to process the token refresh
                import asyncio
                await asyncio.sleep(5)
            except Exception:  # noqa: BLE001
                pass

    except Exception as exc:  # noqa: BLE001
        logger.warning("temp_chat.ensure_agent_ready.failed", extra={"error": str(exc)})
        await session.commit()


def _write_token_to_tools(agent: Agent, token: str) -> None:
    """Write the new token to the agent's TOOLS.md on the host filesystem."""
    import os
    import json
    import re
    from pathlib import Path

    # Resolve workspace path from openclaw config
    config_path = os.environ.get("OPENCLAW_CONFIG_PATH", "/root/.openclaw/openclaw.json")
    remap_env = os.environ.get("WORKSPACE_ROOT_REMAP", "")

    if not agent.openclaw_session_id:
        return

    # Extract config_id from session key: "agent:{config_id}:main"
    parts = agent.openclaw_session_id.split(":")
    if len(parts) < 2 or parts[0] != "agent":
        return
    config_id = parts[1]

    # Try to find the workspace path
    try:
        with open(config_path) as f:
            config = json.load(f)
    except (OSError, json.JSONDecodeError):
        return

    workspace = None
    for entry in config.get("agents", {}).get("list", []):
        if entry.get("id") == config_id:
            workspace = entry.get("workspace")
            break

    if not workspace:
        return

    # Apply workspace remap if configured
    if "=" in remap_env:
        src, dst = remap_env.split("=", 1)
        if workspace.startswith(src.rstrip("/")):
            workspace = dst.rstrip("/") + workspace[len(src.rstrip("/")):]

    tools_path = Path(workspace) / "TOOLS.md"
    if not tools_path.exists():
        return

    try:
        content = tools_path.read_text()
        content = re.sub(r'AUTH_TOKEN=[^\s`]+', f'AUTH_TOKEN={token}', content)
        content = re.sub(r'X-Agent-Token: [^\s"\\]+', f'X-Agent-Token: {token}', content)
        tools_path.write_text(content)
    except OSError:
        pass


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





async def _send_and_wait(
    *,
    session_key: str,
    message: str,
    config: GatewayConfig,
) -> str:
    """Send a message to the lead agent and wait for the reply.

    Strategy: snapshot the message count before sending, then after agent.wait
    completes, look for assistant messages with seq > our user message's seq.
    This avoids false-matching stale replies from prior conversations.
    """
    import asyncio
    import time

    # Snapshot history to find the current max seq number
    pre_history = await openclaw_call(
        "chat.history",
        {"sessionKey": session_key, "limit": 3},
        config=config,
    )
    pre_messages = pre_history.get("messages") or [] if isinstance(pre_history, dict) else []
    max_pre_seq = 0
    for m in pre_messages:
        seq = (m.get("__openclaw") or {}).get("seq", 0)
        if isinstance(seq, (int, float)) and seq > max_pre_seq:
            max_pre_seq = seq

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

    deadline = sent_at + _WAIT_TIMEOUT_MS / 1000

    # Our user message will have seq = max_pre_seq + 1 (approximately).
    # We want an assistant reply with seq > max_pre_seq + 1.
    user_seq = max_pre_seq + 1

    while time.monotonic() < deadline:
        remaining_ms = max(1000, int((deadline - time.monotonic()) * 1000))
        await openclaw_call(
            "agent.wait",
            {"runId": run_id, "timeoutMs": min(remaining_ms, 30_000)},
            config=config,
        )

        text = await _get_reply_after_seq(session_key, user_seq, config)
        if text:
            return text

        # Grace period for multi-turn tool usage
        await asyncio.sleep(1.5)
        text = await _get_reply_after_seq(session_key, user_seq, config)
        if text:
            return text
        break

    # Final attempt
    return await _get_reply_after_seq(session_key, user_seq, config)


async def _get_reply_after_seq(session_key: str, user_seq: int, config: GatewayConfig) -> str:
    """Fetch history and find the last assistant text message with seq > user_seq."""
    history = await openclaw_call(
        "chat.history",
        {"sessionKey": session_key, "limit": 15},
        config=config,
    )
    messages = history.get("messages") or [] if isinstance(history, dict) else []
    for msg in reversed(messages):
        if not isinstance(msg, dict):
            continue
        seq = (msg.get("__openclaw") or {}).get("seq", 0)
        if not isinstance(seq, (int, float)) or seq <= user_seq:
            continue  # This message is from before our send
        if msg.get("role") != "assistant":
            continue
        text = _extract_text_from_msg(msg)
        if text:
            return text
    return ""


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
        # Ensure the lead is alive and has a valid token before sending
        await _ensure_agent_ready(session, agent=lead, board=board)

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
        await _ensure_agent_ready(session, agent=group_agent, board=None)

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
