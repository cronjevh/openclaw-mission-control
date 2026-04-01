"""Worker handlers for lifecycle reconciliation tasks."""

from __future__ import annotations

import asyncio

from app.core.agent_tokens import generate_stable_agent_token
from app.core.logging import get_logger
from app.core.time import utcnow
from app.db.session import async_session_maker
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.services.openclaw.constants import MAX_WAKE_ATTEMPTS_WITHOUT_CHECKIN
from app.services.openclaw.gateway_resolver import optional_gateway_client_config
from app.services.openclaw.gateway_rpc import OpenClawGatewayError
from app.services.openclaw.internal.agent_key import agent_key
from app.services.openclaw.lifecycle_orchestrator import AgentLifecycleOrchestrator
from app.services.openclaw.lifecycle_queue import decode_lifecycle_task, defer_lifecycle_reconcile
from app.services.openclaw.provisioning import OpenClawGatewayControlPlane
from app.services.queue import QueuedTask

logger = get_logger(__name__)
_RECONCILE_TIMEOUT_SECONDS = 60.0


def _has_checked_in_since_wake(agent: Agent) -> bool:
    if agent.last_seen_at is None:
        return False
    if agent.last_wake_sent_at is None:
        return True
    return agent.last_seen_at >= agent.last_wake_sent_at


def _extract_file_content(payload: object) -> str | None:
    if isinstance(payload, str):
        return payload
    if isinstance(payload, dict):
        content = payload.get("content")
        if isinstance(content, str):
            return content
        file_obj = payload.get("file")
        if isinstance(file_obj, dict):
            nested = file_obj.get("content")
            if isinstance(nested, str):
                return nested
    return None


def _parse_auth_token_from_tools(content: str) -> str | None:
    for raw in content.splitlines():
        line = raw.strip()
        if line.startswith("AUTH_TOKEN="):
            token = line.split("=", 1)[1].strip().strip("`")
            return token or None
    return None


async def _resolve_reconcile_auth_token(*, gateway: Gateway, agent: Agent) -> str | None:
    del gateway
    return generate_stable_agent_token(agent.id)


async def process_lifecycle_queue_task(task: QueuedTask) -> None:
    """Re-run lifecycle provisioning when an agent misses post-provision check-in."""
    payload = decode_lifecycle_task(task)
    now = utcnow()

    async with async_session_maker() as session:
        agent = await Agent.objects.by_id(payload.agent_id).first(session)
        if agent is None:
            logger.info(
                "lifecycle.reconcile.skip_missing_agent",
                extra={"agent_id": str(payload.agent_id)},
            )
            return

        # Ignore stale queue messages after a newer lifecycle generation.
        if agent.lifecycle_generation != payload.generation:
            logger.info(
                "lifecycle.reconcile.skip_stale_generation",
                extra={
                    "agent_id": str(agent.id),
                    "queued_generation": payload.generation,
                    "current_generation": agent.lifecycle_generation,
                },
            )
            return

        if _has_checked_in_since_wake(agent):
            logger.info(
                "lifecycle.reconcile.skip_not_stuck",
                extra={"agent_id": str(agent.id), "status": agent.status},
            )
            return

        deadline = agent.checkin_deadline_at or payload.checkin_deadline_at
        if agent.status == "deleting":
            logger.info(
                "lifecycle.reconcile.skip_deleting",
                extra={"agent_id": str(agent.id)},
            )
            return

        if now < deadline:
            delay = max(0.0, (deadline - now).total_seconds())
            if not defer_lifecycle_reconcile(task, delay_seconds=delay):
                msg = "Failed to defer lifecycle reconcile task"
                raise RuntimeError(msg)
            logger.info(
                "lifecycle.reconcile.deferred",
                extra={"agent_id": str(agent.id), "delay_seconds": delay},
            )
            return

        if agent.wake_attempts >= MAX_WAKE_ATTEMPTS_WITHOUT_CHECKIN:
            agent.status = "offline"
            agent.checkin_deadline_at = None
            agent.last_provision_error = (
                "Agent did not check in after wake; max wake attempts reached"
            )
            agent.updated_at = utcnow()
            session.add(agent)
            await session.commit()
            logger.warning(
                "lifecycle.reconcile.max_attempts_reached",
                extra={
                    "agent_id": str(agent.id),
                    "wake_attempts": agent.wake_attempts,
                    "max_attempts": MAX_WAKE_ATTEMPTS_WITHOUT_CHECKIN,
                },
            )
            return

        gateway = await Gateway.objects.by_id(agent.gateway_id).first(session)
        if gateway is None:
            logger.warning(
                "lifecycle.reconcile.skip_missing_gateway",
                extra={"agent_id": str(agent.id), "gateway_id": str(agent.gateway_id)},
            )
            return
        board: Board | None = None
        if agent.board_id is not None:
            board = await Board.objects.by_id(agent.board_id).first(session)
            if board is None:
                logger.warning(
                    "lifecycle.reconcile.skip_missing_board",
                    extra={"agent_id": str(agent.id), "board_id": str(agent.board_id)},
                )
                return

        orchestrator = AgentLifecycleOrchestrator(session)
        auth_token = await _resolve_reconcile_auth_token(gateway=gateway, agent=agent)
        if not auth_token:
            agent.last_provision_error = (
                "Lifecycle reconcile skipped: unable to read AUTH_TOKEN from TOOLS.md"
            )
            agent.updated_at = utcnow()
            session.add(agent)
            await session.commit()
            logger.warning(
                "lifecycle.reconcile.skip_missing_auth_token",
                extra={"agent_id": str(agent.id)},
            )
            return
        await asyncio.wait_for(
            orchestrator.run_lifecycle(
                gateway=gateway,
                agent_id=agent.id,
                board=board,
                user=None,
                action="update",
                auth_token=auth_token,
                force_bootstrap=False,
                # Preserve session context during retries to avoid reset churn.
                reset_session=False,
                wake=True,
                deliver_wakeup=True,
                wakeup_verb="updated",
                clear_confirm_token=True,
                raise_gateway_errors=True,
            ),
            timeout=_RECONCILE_TIMEOUT_SECONDS,
        )
        logger.info(
            "lifecycle.reconcile.retriggered",
            extra={"agent_id": str(agent.id), "generation": payload.generation},
        )
