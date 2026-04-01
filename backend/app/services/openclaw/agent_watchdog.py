"""Agent watchdog — auto-recovers agents stuck in transient states.

Runs as a background task inside the FastAPI lifespan.

Stuck states detected and recovered:
  • "updating"      — stuck > STUCK_UPDATING_AFTER  → reset to "online" + wake
  • "provisioning"  — stuck > STUCK_PROVISION_AFTER → reset to "offline" (needs manual re-provision)

The watchdog only resets agents whose `updated_at` (or `last_seen_at`) has not
changed for longer than the relevant threshold, so in-flight updates are left alone.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import or_, select

from app.core.logging import get_logger
from app.core.time import utcnow
from app.core.agent_tokens import generate_stable_agent_token, hash_agent_token, verify_agent_token
from app.db.session import async_session_maker
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.services.openclaw.constants import MAX_WAKE_ATTEMPTS_WITHOUT_CHECKIN, OFFLINE_AFTER
from app.services.openclaw.gateway_resolver import optional_gateway_client_config
from app.services.openclaw.gateway_rpc import OpenClawGatewayError, openclaw_call
from app.services.openclaw.internal.agent_key import agent_key
from app.services.openclaw.lifecycle_orchestrator import AgentLifecycleOrchestrator
from app.services.openclaw.provisioning import OpenClawGatewayControlPlane
from app.services.openclaw.gateway_rpc import GatewayConfig, send_message

logger = get_logger(__name__)

# How long an agent can stay in "updating" before we consider it stuck
STUCK_UPDATING_AFTER = timedelta(minutes=5)

# How long an agent can stay in "provisioning" before we give up and mark offline
STUCK_PROVISIONING_AFTER = timedelta(minutes=15)

# How often the watchdog polls (seconds)
WATCHDOG_INTERVAL_SECONDS = 60

# Do not send repeated wake attempts too frequently.
WAKE_RETRY_COOLDOWN = timedelta(minutes=2)

# Recovery throughput tuning: process multiple stale agents per sweep.
AUTO_RECOVER_MAX_PER_SWEEP = 8
AUTO_RECOVER_CONCURRENCY = 3


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


async def _resolve_auth_token_for_agent(*, gateway: Gateway, agent: Agent) -> str | None:
    del gateway
    return generate_stable_agent_token(agent.id)


def _needs_auto_recover(agent: Agent, *, now: datetime) -> bool:
    if agent.status == "deleting":
        return False
    if agent.last_wake_sent_at and (now - agent.last_wake_sent_at) < WAKE_RETRY_COOLDOWN:
        return False
    if agent.status in {"offline", "provisioning"}:
        return True
    if agent.last_seen_at is None:
        return True
    return (now - agent.last_seen_at) > OFFLINE_AFTER


async def _latest_gateway_session_activity(
    *,
    gateway: Gateway,
    session_key: str,
) -> datetime | None:
    if not session_key:
        return None
    config = optional_gateway_client_config(gateway)
    if config is None:
        return None
    try:
        payload = await openclaw_call("sessions.list", {}, config=config)
    except OpenClawGatewayError:
        return None
    if not isinstance(payload, dict):
        return None
    sessions = payload.get("sessions")
    if not isinstance(sessions, list):
        return None
    for item in sessions:
        if not isinstance(item, dict):
            continue
        if item.get("key") != session_key:
            continue
        updated_at_ms = item.get("updatedAt")
        if isinstance(updated_at_ms, (int, float)):
            return datetime.utcfromtimestamp(float(updated_at_ms) / 1000.0)
    return None


async def _recover_unchecked_agents(now: datetime) -> int:
    """Wake agents that are stale/offline after restart without manual intervention."""
    async with async_session_maker() as db:
        result = await db.execute(
            select(Agent).where(
                Agent.status != "deleting",
                or_(
                    Agent.status.in_(["offline", "provisioning"]),
                    Agent.last_seen_at.is_(None),
                    Agent.last_seen_at < (now - OFFLINE_AFTER),
                ),
            )
        )
        candidate_ids = [agent.id for agent in result.scalars().all()][:AUTO_RECOVER_MAX_PER_SWEEP]

    semaphore = asyncio.Semaphore(AUTO_RECOVER_CONCURRENCY)

    async def _guarded_recover(agent_id: UUID) -> bool:
        async with semaphore:
            return await _recover_single_agent(agent_id=agent_id, now=now)

    results = await asyncio.gather(*[_guarded_recover(agent_id) for agent_id in candidate_ids])
    return sum(1 for recovered in results if recovered)


async def _recover_single_agent(*, agent_id: UUID, now: datetime) -> bool:
    """Recover one agent in its own session to allow bounded concurrency."""
    async with async_session_maker() as db:
        agent = await db.get(Agent, agent_id)
        if agent is None or not _needs_auto_recover(agent, now=now):
            return False

        gateway_result = await db.execute(select(Gateway).where(Gateway.id == agent.gateway_id))
        gateway = gateway_result.scalar_one_or_none()
        if gateway is None:
            return False

        session_activity = await _latest_gateway_session_activity(
            gateway=gateway,
            session_key=agent.openclaw_session_id or "",
        )
        if session_activity is not None and (
            agent.last_seen_at is None or session_activity > agent.last_seen_at
        ):
            agent.last_seen_at = session_activity
            agent.status = "online"
            agent.checkin_deadline_at = None
            agent.last_provision_error = None
            agent.updated_at = now
            db.add(agent)
            await db.commit()
            logger.info(
                "watchdog.auto_recover.session_activity_seen",
                extra={
                    "agent_id": str(agent.id),
                    "agent_name": agent.name,
                    "session_activity": session_activity.isoformat(),
                },
            )
            return True

        auth_token = await _resolve_auth_token_for_agent(gateway=gateway, agent=agent)
        if not auth_token:
            logger.warning(
                "watchdog.auto_recover.skip_missing_auth_token",
                extra={"agent_id": str(agent.id), "agent_name": agent.name},
            )
            return False

        # Reconcile stored hash to the stable token derived for this agent.
        if not agent.agent_token_hash or not verify_agent_token(auth_token, agent.agent_token_hash):
            agent.agent_token_hash = hash_agent_token(auth_token)
            agent.updated_at = now
            db.add(agent)
            await db.flush()

        board: Board | None = None
        if agent.board_id is not None:
            board_result = await db.execute(select(Board).where(Board.id == agent.board_id))
            board = board_result.scalar_one_or_none()

        if agent.wake_attempts >= MAX_WAKE_ATTEMPTS_WITHOUT_CHECKIN:
            # Prevent permanent deadlock at max attempts; watchdog will re-wake safely.
            agent.wake_attempts = 0
            agent.checkin_deadline_at = None
            agent.last_provision_error = None
            agent.updated_at = now
            db.add(agent)
            await db.flush()

        try:
            await AgentLifecycleOrchestrator(db).run_lifecycle(
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
                raise_gateway_errors=False,
            )

            # Lifecycle success is not the same as agent responsiveness.
            # Keep status in "updating" until a real heartbeat/request confirms liveness.
            refreshed = await db.get(Agent, agent.id)
            if refreshed is not None:
                refreshed.status = "updating"
                refreshed.last_provision_error = None
                refreshed.updated_at = now
                db.add(refreshed)
                await db.commit()

            return True
        except (HTTPException, OpenClawGatewayError, OSError, RuntimeError, ValueError) as exc:
            logger.warning(
                "watchdog.auto_recover.failed",
                extra={"agent_id": str(agent.id), "agent_name": agent.name, "error": str(exc)},
            )
            return False


async def _recover_stuck_updating(now: datetime) -> int:
    """Reset agents stuck in 'updating' → 'online' and send a wake message."""
    cutoff = now - STUCK_UPDATING_AFTER
    recovered = 0

    async with async_session_maker() as db:
        result = await db.execute(
            select(Agent).where(
                Agent.status == "updating",
                Agent.updated_at < cutoff,
            )
        )
        stuck_agents = result.scalars().all()

        for agent in stuck_agents:
            logger.warning(
                "watchdog.stuck_updating.recovering",
                extra={
                    "agent_id": str(agent.id),
                    "agent_name": agent.name,
                    "stuck_since": str(agent.updated_at),
                },
            )
            # Reset state
            agent.status = "online"
            agent.provision_action = None
            agent.last_provision_error = "Auto-recovered by watchdog (stuck in updating)"
            agent.updated_at = now
            db.add(agent)

        await db.commit()

        # Send wake messages outside the commit so failures don't roll back the reset
        for agent in stuck_agents:
            if not agent.openclaw_session_id or not agent.gateway_id:
                continue
            try:
                async with async_session_maker() as gw_db:
                    gw_result = await gw_db.execute(
                        select(Gateway).where(Gateway.id == agent.gateway_id)
                    )
                    gateway = gw_result.scalar_one_or_none()
                    if gateway is None:
                        continue
                    config = GatewayConfig(url=gateway.url, token=gateway.token)
                    await send_message(
                        "Resume your current task. Check your assigned tasks on the board and continue working.",
                        session_key=agent.openclaw_session_id,
                        config=config,
                    )
                    logger.info(
                        "watchdog.stuck_updating.wake_sent",
                        extra={"agent_id": str(agent.id), "agent_name": agent.name},
                    )
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "watchdog.stuck_updating.wake_failed",
                    extra={"agent_id": str(agent.id), "error": str(exc)},
                )
            recovered += 1

    return recovered


async def _recover_stuck_provisioning(now: datetime) -> int:
    """Mark agents stuck in 'provisioning' as offline so they can be retried."""
    cutoff = now - STUCK_PROVISIONING_AFTER
    recovered = 0

    async with async_session_maker() as db:
        result = await db.execute(
            select(Agent).where(
                Agent.status == "provisioning",
                Agent.updated_at < cutoff,
            )
        )
        stuck_agents = result.scalars().all()

        for agent in stuck_agents:
            logger.warning(
                "watchdog.stuck_provisioning.marking_offline",
                extra={
                    "agent_id": str(agent.id),
                    "agent_name": agent.name,
                    "stuck_since": str(agent.updated_at),
                },
            )
            agent.status = "offline"
            agent.provision_action = None
            agent.last_provision_error = "Auto-marked offline by watchdog (stuck in provisioning)"
            agent.updated_at = now
            db.add(agent)
            recovered += 1

        await db.commit()

    return recovered


async def run_watchdog_once() -> None:
    """Run one watchdog sweep. Safe to call manually for testing."""
    now = utcnow()
    try:
        updating_recovered = await _recover_stuck_updating(now)
        provisioning_recovered = await _recover_stuck_provisioning(now)
        auto_recovered = await _recover_unchecked_agents(now)
        if updating_recovered or provisioning_recovered or auto_recovered:
            logger.info(
                "watchdog.sweep.recovered",
                extra={
                    "updating_recovered": updating_recovered,
                    "provisioning_recovered": provisioning_recovered,
                    "auto_recovered": auto_recovered,
                },
            )
        else:
            logger.debug("watchdog.sweep.nothing_to_recover")
    except Exception as exc:  # noqa: BLE001
        logger.exception("watchdog.sweep.error", extra={"error": str(exc)})


async def watchdog_loop() -> None:
    """Background loop — runs forever inside the FastAPI lifespan."""
    logger.info(
        "watchdog.started",
        extra={
            "interval_seconds": WATCHDOG_INTERVAL_SECONDS,
            "stuck_updating_after_minutes": STUCK_UPDATING_AFTER.total_seconds() / 60,
            "stuck_provisioning_after_minutes": STUCK_PROVISIONING_AFTER.total_seconds() / 60,
        },
    )
    while True:
        await run_watchdog_once()
        await asyncio.sleep(WATCHDOG_INTERVAL_SECONDS)
