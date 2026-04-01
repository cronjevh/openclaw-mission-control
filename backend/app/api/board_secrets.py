"""Board secrets CRUD — encrypted per-board credentials for agents."""

from __future__ import annotations

import asyncio
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from pydantic import BaseModel
from sqlmodel import col, select
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api.deps import get_board_for_actor_read, get_board_for_user_write
from app.core.encryption import decrypt_secret, encrypt_secret
from app.core.logging import get_logger
from app.core.time import utcnow
from app.db.session import async_session_maker, get_session
from app.models.agents import Agent
from app.models.board_secrets import BoardSecret
from app.models.boards import Board
from app.models.gateways import Gateway
from app.services.openclaw.lifecycle_orchestrator import AgentLifecycleOrchestrator

router = APIRouter(tags=["board-secrets"])
logger = get_logger(__name__)

SESSION_DEP = Depends(get_session)
BOARD_WRITE_DEP = Depends(get_board_for_user_write)
BOARD_READ_DEP = Depends(get_board_for_actor_read)


class SecretRead(BaseModel):
    id: UUID
    key: str
    description: str
    has_value: bool = True

    model_config = {"from_attributes": True}


class SecretWrite(BaseModel):
    key: str
    value: str
    description: str = ""


async def _reprovision_board_agents(board_id: UUID) -> None:
    """Re-provision all online agents on a board so they get updated secrets in TOOLS.md."""
    async with async_session_maker() as session:
        result = await session.exec(
            select(Agent).where(
                Agent.board_id == board_id,
                col(Agent.status).in_(["online", "provisioning", "updating"]),
            )
        )
        agents = result.all()
        if not agents:
            return

        board_result = await session.exec(select(Board).where(Board.id == board_id))
        board = board_result.first()
        if not board:
            return

        orchestrator = AgentLifecycleOrchestrator(session)
        for agent in agents:
            try:
                gateway_result = await session.exec(
                    select(Gateway).where(Gateway.id == agent.gateway_id)
                )
                gateway = gateway_result.first()
                if not gateway:
                    continue
                await orchestrator.run_lifecycle(
                    gateway=gateway,
                    agent_id=agent.id,
                    board=board,
                    user=None,
                    action="update",
                    reset_session=False,
                    wake=False,
                    deliver_wakeup=False,
                    clear_confirm_token=False,
                    raise_gateway_errors=False,
                )
                logger.info(
                    "board_secrets.reprovision.ok",
                    extra={"agent_id": str(agent.id), "agent_name": agent.name},
                )
            except Exception as exc:
                logger.warning(
                    "board_secrets.reprovision.failed",
                    extra={"agent_id": str(agent.id), "error": str(exc)},
                )


@router.get("/boards/{board_id}/secrets", response_model=list[SecretRead])
async def list_secrets(
    board_id: UUID,
    board: Board = BOARD_READ_DEP,
    session: AsyncSession = SESSION_DEP,
) -> list[SecretRead]:
    """List secret keys for a board (values never returned)."""
    result = await session.exec(
        select(BoardSecret)
        .where(BoardSecret.board_id == board_id)
        .order_by(col(BoardSecret.key))
    )
    secrets = result.all()
    return [SecretRead(id=s.id, key=s.key, description=s.description) for s in secrets]


@router.put("/boards/{board_id}/secrets/{key}", response_model=SecretRead)
async def upsert_secret(
    board_id: UUID,
    key: str,
    payload: SecretWrite,
    background_tasks: BackgroundTasks,
    board: Board = BOARD_WRITE_DEP,
    session: AsyncSession = SESSION_DEP,
) -> SecretRead:
    """Create or update a secret for a board. Re-provisions all board agents in background."""
    key = key.upper().strip()
    if not key:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Key required")

    result = await session.exec(
        select(BoardSecret).where(
            BoardSecret.board_id == board_id, BoardSecret.key == key
        )
    )
    secret = result.first()
    now = utcnow()

    if secret:
        secret.encrypted_value = encrypt_secret(payload.value)
        secret.description = payload.description
        secret.updated_at = now
    else:
        secret = BoardSecret(
            board_id=board_id,
            organization_id=board.organization_id,
            key=key,
            encrypted_value=encrypt_secret(payload.value),
            description=payload.description,
            created_at=now,
            updated_at=now,
        )
        session.add(secret)

    await session.commit()
    await session.refresh(secret)

    # Re-provision agents in background so they pick up the new secret immediately.
    background_tasks.add_task(_reprovision_board_agents, board_id)

    return SecretRead(id=secret.id, key=secret.key, description=secret.description)


@router.delete("/boards/{board_id}/secrets/{key}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_secret(
    board_id: UUID,
    key: str,
    background_tasks: BackgroundTasks,
    board: Board = BOARD_WRITE_DEP,
    session: AsyncSession = SESSION_DEP,
) -> None:
    """Delete a secret. Re-provisions all board agents in background."""
    result = await session.exec(
        select(BoardSecret).where(
            BoardSecret.board_id == board_id, BoardSecret.key == key.upper()
        )
    )
    secret = result.first()
    if not secret:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Secret not found")
    await session.delete(secret)
    await session.commit()

    background_tasks.add_task(_reprovision_board_agents, board_id)
