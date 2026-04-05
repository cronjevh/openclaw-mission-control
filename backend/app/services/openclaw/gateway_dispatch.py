"""DB-backed gateway config resolution and message dispatch helpers.

This module exists to keep `app.api.*` thin: APIs should call OpenClaw services, not
directly orchestrate gateway RPC calls.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING
from uuid import UUID, uuid4

from sqlalchemy import func, or_
from sqlmodel import col, select

from app.models.board_memory import BoardMemory
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.tasks import Task
from app.services.openclaw.constants import OFFLINE_AFTER
from app.services.openclaw.db_service import OpenClawDBService
from app.services.openclaw.gateway_resolver import (
    gateway_client_config,
    get_gateway_for_board,
    optional_gateway_client_config,
    require_gateway_for_board,
)
from app.services.openclaw.gateway_rpc import GatewayConfig as GatewayClientConfig
from app.services.openclaw.gateway_rpc import OpenClawGatewayError, ensure_session, send_message

if TYPE_CHECKING:
    from app.models.agents import Agent


_CONTROL_COMMANDS = frozenset({"/pause", "/resume", "/new"})
_PAUSE_STATE_COMMANDS = frozenset({"/pause", "/resume"})


def _is_agent_offline(last_seen_at: datetime | None) -> bool:
    """Return True if the agent hasn't been seen within OFFLINE_AFTER."""
    if last_seen_at is None:
        return True
    ts = last_seen_at if last_seen_at.tzinfo else last_seen_at.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - ts) > OFFLINE_AFTER


class GatewayDispatchService(OpenClawDBService):
    """Resolve gateway config for boards and dispatch messages to agent sessions."""

    async def optional_gateway_config_for_board(
        self,
        board: Board,
    ) -> GatewayClientConfig | None:
        gateway = await get_gateway_for_board(self.session, board)
        return optional_gateway_client_config(gateway)

    async def require_gateway_config_for_board(
        self,
        board: Board,
    ) -> tuple[Gateway, GatewayClientConfig]:
        gateway = await require_gateway_for_board(self.session, board)
        return gateway, gateway_client_config(gateway)

    async def wake_agent_if_offline(
        self,
        *,
        agent: "Agent",
        board: Board | None = None,
    ) -> None:
        """Full re-provision + wake if agent appears offline. Silently ignores errors.

        Uses run_lifecycle(action="update") which idempotently re-syncs files and
        sends the wake message — reliable even when the agent session is fully dead.
        Falls back to a bare send_message if the board/gateway context is missing.
        """
        if not _is_agent_offline(agent.last_seen_at):
            return

        logger = _get_logger()
        logger.info(
            "dispatch.wake_agent.reprovision",
            extra={"agent_name": agent.name, "agent_id": str(agent.id)},
        )

        try:
            from app.models.gateways import Gateway as GatewayModel
            from app.services.openclaw.lifecycle_orchestrator import AgentLifecycleOrchestrator
            from app.core.time import utcnow

            gateway = await GatewayModel.objects.by_id(agent.gateway_id).first(self.session)
            if gateway is None:
                logger.warning("dispatch.wake_agent.no_gateway", extra={"agent_id": str(agent.id)})
                return

            # Resolve the board if not supplied
            resolved_board = board
            if resolved_board is None and agent.board_id is not None:
                resolved_board = await Board.objects.by_id(agent.board_id).first(self.session)

            # Reset stale offline state so run_lifecycle doesn't get blocked by
            # max-wake-attempts from a previous dead cycle.
            if agent.status == "offline" or agent.wake_attempts >= 3:
                agent.status = "online"
                agent.wake_attempts = 0
                agent.provision_action = None
                agent.checkin_deadline_at = None
                agent.last_provision_error = None
                agent.updated_at = utcnow()
                self.session.add(agent)
                await self.session.flush()

            orchestrator = AgentLifecycleOrchestrator(self.session)
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
            logger.info(
                "dispatch.wake_agent.reprovision.ok",
                extra={"agent_name": agent.name},
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "dispatch.wake_agent.reprovision.failed",
                extra={"agent_name": agent.name, "error": str(exc)},
            )

    async def send_agent_message(
        self,
        *,
        session_key: str,
        config: GatewayClientConfig,
        agent_name: str,
        message: str,
        deliver: bool = False,
        agent: "Agent | None" = None,
        board: Board | None = None,
    ) -> None:
        resolved_board = await self._resolve_board_for_pause_check(
            board=board,
            agent=agent,
            session_key=session_key,
        )
        if await self._should_skip_for_paused_board(board=resolved_board, message=message):
            raise OpenClawGatewayError("Board agents are paused. Send /resume to continue.")

        # Resolve agent if not provided (for task check and waking)
        resolved_agent = agent
        if resolved_agent is None and resolved_board is not None:
            from app.models.agents import Agent as AgentModel
            resolved_agent = await AgentModel.objects.filter_by(openclaw_session_id=session_key).first(
                self.session,
            )

        # Only allow LLM-triggering messages if agent has attention tasks
        if resolved_agent is not None and resolved_board is not None:
            command = message.strip().lower()
            if command not in _CONTROL_COMMANDS:
                if not await self._agent_has_attention_tasks(resolved_board, resolved_agent):
                    raise OpenClawGatewayError("Agent has no tasks requiring attention")

        # Full re-provision wake for offline agents before delivering the notification.
        if resolved_agent is not None:
            await self.wake_agent_if_offline(agent=resolved_agent, board=resolved_board)
        await ensure_session(session_key, config=config, label=agent_name)
        await send_message(message, session_key=session_key, config=config, deliver=deliver)

    async def try_send_agent_message(
        self,
        *,
        session_key: str,
        config: GatewayClientConfig,
        agent_name: str,
        message: str,
        deliver: bool = False,
        agent: "Agent | None" = None,
        board: Board | None = None,
        last_seen_at: datetime | None = None,  # legacy compat, prefer agent=
    ) -> OpenClawGatewayError | None:
        resolved_board = await self._resolve_board_for_pause_check(
            board=board,
            agent=agent,
            session_key=session_key,
        )
        if await self._should_skip_for_paused_board(board=resolved_board, message=message):
            return OpenClawGatewayError("Board agents are paused. Send /resume to continue.")

        # Support legacy last_seen_at callers by synthesising a minimal wake check.
        effective_agent = agent
        if effective_agent is None and last_seen_at is not None and _is_agent_offline(last_seen_at):
            # Can't re-provision without the full Agent object; best-effort send_message wake.
            _wake_config = config
            _session_key = session_key
            logger = _get_logger()
            logger.info("dispatch.wake_agent.legacy", extra={"agent_name": agent_name})
            try:
                from app.services.openclaw.gateway_rpc import send_message as _sm
                await ensure_session(_session_key, config=_wake_config, label=agent_name)
                await _sm(
                    "Read HEARTBEAT.md if it exists. Follow it strictly. "
                    "If nothing needs attention, reply HEARTBEAT_OK.",
                    session_key=_session_key,
                    config=_wake_config,
                    deliver=True,
                )
            except OpenClawGatewayError:
                pass

        try:
            await self.send_agent_message(
                session_key=session_key,
                config=config,
                agent_name=agent_name,
                message=message,
                deliver=deliver,
                agent=effective_agent,
                board=resolved_board,
            )
        except OpenClawGatewayError as exc:
            return exc
        return None

    async def _resolve_board_for_pause_check(
        self,
        *,
        board: Board | None,
        agent: "Agent | None",
        session_key: str,
    ) -> Board | None:
        if board is not None:
            return board

        if agent is not None and agent.board_id is not None:
            resolved = await Board.objects.by_id(agent.board_id).first(self.session)
            if resolved is not None:
                return resolved

        if not session_key:
            return None

        from app.models.agents import Agent as AgentModel

        session_agent = await AgentModel.objects.filter_by(openclaw_session_id=session_key).first(
            self.session,
        )
        if session_agent is None or session_agent.board_id is None:
            return None
        return await Board.objects.by_id(session_agent.board_id).first(self.session)

    async def _should_skip_for_paused_board(
        self,
        *,
        board: Board | None,
        message: str,
    ) -> bool:
        if board is None:
            return False
        command = message.strip().lower()
        if command in _CONTROL_COMMANDS:
            return False
        return await self._is_board_paused(board.id)

    async def _is_board_paused(self, board_id: UUID) -> bool:
        statement = (
            select(BoardMemory.content)
            .where(col(BoardMemory.board_id) == board_id)
            .where(col(BoardMemory.is_chat).is_(True))
            # `/new` is allowed while paused, but it must not toggle paused state.
            .where(func.lower(func.trim(col(BoardMemory.content))).in_(set(_PAUSE_STATE_COMMANDS)))
            .order_by(col(BoardMemory.created_at).desc())
            .limit(1)
        )
        content = (await self.session.exec(statement)).first()
        if not isinstance(content, str):
            return False
        return content.strip().lower() == "/pause"

    async def _agent_has_attention_tasks(self, board: Board, agent: Agent) -> bool:
        """Check if the agent has any tasks requiring its attention on this board."""
        query = select(Task.id).where(col(Task.board_id) == board.id).where(col(Task.status) != "done")
        if agent.is_board_lead:
            # Lead cares about unassigned inbox tasks and tasks assigned to them
            query = query.where(
                or_(
                    col(Task.assigned_agent_id) == agent.id,
                    (col(Task.assigned_agent_id).is_(None) & (col(Task.status) == "inbox")),
                )
            )
        else:
            query = query.where(col(Task.assigned_agent_id) == agent.id)
        result = await self.session.exec(query.limit(1))
        return result.first() is not None

    @staticmethod
    def resolve_trace_id(correlation_id: str | None, *, prefix: str) -> str:
        normalized = (correlation_id or "").strip()
        if normalized:
            return normalized
        return f"{prefix}:{uuid4().hex[:12]}"


def _get_logger():  # type: ignore[return]
    from app.core.logging import get_logger

    return get_logger(__name__)
