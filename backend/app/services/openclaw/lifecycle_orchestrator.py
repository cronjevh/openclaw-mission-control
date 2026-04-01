"""Unified agent lifecycle orchestration.

This module centralizes DB-backed lifecycle transitions so call sites do not
duplicate provisioning/wake/state logic.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from uuid import UUID

from fastapi import HTTPException, status
from sqlmodel import col, select

from app.core.time import utcnow
from app.models.agents import Agent
from app.models.board_secrets import BoardSecret
from app.models.board_documents import BoardDocument
from app.models.boards import Board
from app.models.gateways import Gateway
from app.services.agent_capabilities import (
    filter_secret_keys_for_capabilities,
    resolve_agent_capabilities,
)
from app.services.openclaw.constants import CHECKIN_DEADLINE_AFTER_WAKE
from app.services.openclaw.db_agent_state import (
    mark_provision_complete,
    mark_provision_requested,
    mint_agent_token,
)
from app.core.agent_tokens import hash_agent_token
from app.services.openclaw.db_service import OpenClawDBService
from app.services.openclaw.gateway_resolver import optional_gateway_client_config
from app.services.openclaw.gateway_rpc import OpenClawGatewayError
from app.services.openclaw.internal.agent_key import agent_key
from app.services.openclaw.provisioning import OpenClawGatewayControlPlane
from app.services.openclaw.lifecycle_queue import (
    QueuedAgentLifecycleReconcile,
    enqueue_lifecycle_reconcile,
)
from app.services.openclaw.provisioning import OpenClawGatewayProvisioner
from app.services.organizations import get_org_owner_user
from app.core.logging import get_logger

if TYPE_CHECKING:
    from sqlmodel.ext.asyncio.session import AsyncSession

    from app.models.users import User


logger = get_logger(__name__)


class AgentLifecycleOrchestrator(OpenClawDBService):
    """Single lifecycle writer for agent provision/update transitions."""

    def __init__(self, session: AsyncSession) -> None:
        super().__init__(session)

    async def _lock_agent(self, *, agent_id: UUID) -> Agent:
        statement = select(Agent).where(col(Agent.id) == agent_id).with_for_update()
        agent = (await self.session.exec(statement)).first()
        if agent is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Agent not found")
        return agent

    @staticmethod
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

    @staticmethod
    def _parse_auth_token_from_tools(content: str) -> str | None:
        for raw in content.splitlines():
            line = raw.strip()
            if line.startswith("AUTH_TOKEN="):
                token = line.split("=", 1)[1].strip().strip("`")
                return token or None
        return None

    async def _resolve_update_auth_token(self, *, gateway: Gateway, agent: Agent) -> str | None:
        config = optional_gateway_client_config(gateway)
        if config is None:
            logger.warning(
                "lifecycle.orchestrator.auth_token_unavailable",
                extra={
                    "agent_id": str(agent.id),
                    "reason": "missing_gateway_client_config",
                },
            )
            return None
        control_plane = OpenClawGatewayControlPlane(config)
        try:
            payload = await control_plane.get_agent_file_payload(
                agent_id=agent_key(agent),
                name="TOOLS.md",
            )
        except OpenClawGatewayError as exc:
            logger.warning(
                "lifecycle.orchestrator.auth_token_unavailable",
                extra={
                    "agent_id": str(agent.id),
                    "reason": "tools_read_failed",
                    "error": str(exc),
                },
            )
            return None
        tools = self._extract_file_content(payload)
        if not tools:
            logger.warning(
                "lifecycle.orchestrator.auth_token_unavailable",
                extra={
                    "agent_id": str(agent.id),
                    "reason": "tools_content_missing",
                },
            )
            return None
        token = self._parse_auth_token_from_tools(tools)
        if not token:
            logger.warning(
                "lifecycle.orchestrator.auth_token_unavailable",
                extra={
                    "agent_id": str(agent.id),
                    "reason": "auth_token_not_found",
                },
            )
        return token

    async def run_lifecycle(
        self,
        *,
        gateway: Gateway,
        agent_id: UUID,
        board: Board | None,
        user: User | None,
        action: str,
        auth_token: str | None = None,
        force_bootstrap: bool = False,
        overwrite: bool = False,
        reset_session: bool = False,
        wake: bool = True,
        deliver_wakeup: bool = True,
        wakeup_verb: str | None = None,
        clear_confirm_token: bool = False,
        raise_gateway_errors: bool = True,
    ) -> Agent:
        """Provision or update any agent under a per-agent lock."""

        locked = await self._lock_agent(agent_id=agent_id)
        template_user = user
        if board is None and template_user is None:
            template_user = await get_org_owner_user(
                self.session,
                organization_id=gateway.organization_id,
            )
            if template_user is None:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail=(
                        "Organization owner not found "
                        "(required for gateway agent USER.md rendering)."
                    ),
                )

        raw_token = auth_token
        if not raw_token:
            raw_token = mint_agent_token(locked)
        mark_provision_requested(
            locked,
            action=action,
            status="updating" if action == "update" else "provisioning",
        )
        locked.lifecycle_generation += 1
        locked.last_provision_error = None
        locked.checkin_deadline_at = utcnow() + CHECKIN_DEADLINE_AFTER_WAKE if wake else None
        if wake:
            locked.wake_attempts += 1
            locked.last_wake_sent_at = utcnow()
        self.session.add(locked)
        await self.session.flush()

        if not gateway.url:
            await self.session.commit()
            await self.session.refresh(locked)
            return locked

        # Load board secret metadata (keys + descriptions only — no values written to disk).
        board_secrets: list[dict[str, str]] = []
        if board is not None:
            secrets_result = await self.session.exec(
                select(BoardSecret).where(BoardSecret.board_id == board.id)
            )
            for s in secrets_result.all():
                board_secrets.append({
                    "key": s.key,
                    "description": s.description,
                })
            board_secrets = filter_secret_keys_for_capabilities(
                board_secrets,
                resolve_agent_capabilities(locked.identity_profile),
            )

        # Load board documents/guides for agent context.
        board_documents: list[dict[str, str]] = []
        if board is not None:
            docs_result = await self.session.exec(
                select(BoardDocument)
                .where(BoardDocument.board_id == board.id)
                .order_by(BoardDocument.order, BoardDocument.created_at)
            )
            for doc in docs_result.all():
                board_documents.append({
                    "title": doc.title,
                    "description": doc.description or "",
                    "content": doc.content,
                })

        try:
            await OpenClawGatewayProvisioner().apply_agent_lifecycle(
                agent=locked,
                gateway=gateway,
                board=board,
                auth_token=raw_token,
                user=template_user,
                action=action,
                force_bootstrap=force_bootstrap,
                overwrite=overwrite,
                reset_session=reset_session,
                wake=wake,
                deliver_wakeup=deliver_wakeup,
                wakeup_verb=wakeup_verb,
                board_secrets=board_secrets,
                board_documents=board_documents,
            )
        except OpenClawGatewayError as exc:
            locked.last_provision_error = str(exc)
            locked.updated_at = utcnow()
            self.session.add(locked)
            await self.session.commit()
            await self.session.refresh(locked)
            if raise_gateway_errors:
                raise HTTPException(
                    status_code=status.HTTP_502_BAD_GATEWAY,
                    detail=f"Gateway {action} failed: {exc}",
                ) from exc
            return locked
        except (OSError, RuntimeError, ValueError) as exc:
            locked.last_provision_error = str(exc)
            locked.updated_at = utcnow()
            self.session.add(locked)
            await self.session.commit()
            await self.session.refresh(locked)
            if raise_gateway_errors:
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail=f"Unexpected error {action}ing gateway provisioning.",
                ) from exc
            return locked

        locked.agent_token_hash = hash_agent_token(raw_token)

        mark_provision_complete(
            locked,
            status="online",
            clear_confirm_token=clear_confirm_token,
        )
        locked.last_provision_error = None
        locked.checkin_deadline_at = utcnow() + CHECKIN_DEADLINE_AFTER_WAKE if wake else None
        self.session.add(locked)
        await self.session.commit()
        await self.session.refresh(locked)
        if wake and locked.checkin_deadline_at is not None:
            enqueue_lifecycle_reconcile(
                QueuedAgentLifecycleReconcile(
                    agent_id=locked.id,
                    gateway_id=locked.gateway_id,
                    board_id=locked.board_id,
                    generation=locked.lifecycle_generation,
                    checkin_deadline_at=locked.checkin_deadline_at,
                )
            )
        return locked
