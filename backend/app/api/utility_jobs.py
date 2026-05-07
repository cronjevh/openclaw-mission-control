"""Utility job CRUD endpoints for GUI-managed deterministic cron tasks."""

from __future__ import annotations

from typing import TYPE_CHECKING
from uuid import UUID
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func
from sqlmodel import col, select

from app.api.deps import require_org_admin, require_org_member
from app.core.time import utcnow
from app.db import crud
from app.db.pagination import paginate
from app.db.session import get_session
from app.models.agents import Agent
from app.models.boards import Board
from app.models.utility_jobs import UtilityJob
from app.schemas.common import OkResponse
from app.schemas.pagination import DefaultLimitOffsetPage
from app.schemas.utility_jobs import (
    UtilityJobCreate,
    UtilityJobRead,
    UtilityJobScriptOption,
    UtilityJobUpdate,
)
from app.services.organizations import OrganizationContext
from app.services.utility_job_crontab import (
    enqueue_utility_job_crontab,
    script_options,
    validate_cron_expression,
    validate_script_key,
    LOG_DIR,
)

if TYPE_CHECKING:
    from fastapi_pagination.limit_offset import LimitOffsetPage
    from sqlmodel.ext.asyncio.session import AsyncSession

router = APIRouter(prefix="/jobs", tags=["jobs"])
SESSION_DEP = Depends(get_session)
ORG_MEMBER_DEP = Depends(require_org_member)
ORG_ADMIN_DEP = Depends(require_org_admin)


async def _require_org_job(
    session: AsyncSession,
    *,
    job_id: UUID,
    ctx: OrganizationContext,
) -> UtilityJob:
    job = await UtilityJob.objects.by_id(job_id).first(session)
    if job is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if job.organization_id != ctx.organization.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    return job


async def _validate_scope(
    session: AsyncSession,
    *,
    organization_id: UUID,
    board_id: UUID | None,
    agent_id: UUID | None,
) -> None:
    if board_id is not None:
        board = await crud.get_by_id(session, Board, board_id)
        if board is None or board.organization_id != organization_id:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="board_id is invalid",
            )
    if agent_id is not None:
        if board_id is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="board_id is required when agent_id is set",
            )
        agent = await crud.get_by_id(session, Agent, agent_id)
        if agent is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="agent_id is invalid",
            )
        if agent.board_id != board_id:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="agent_id must belong to the selected board",
            )


def _validate_job_fields(*, cron_expression: str, script_key: str) -> None:
    try:
        validate_cron_expression(cron_expression)
        validate_script_key(script_key)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=str(exc),
        ) from exc


@router.get("", response_model=DefaultLimitOffsetPage[UtilityJobRead])
async def list_utility_jobs(
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_MEMBER_DEP,
) -> LimitOffsetPage[UtilityJobRead]:
    """List utility jobs for the active organization."""
    statement = (
        select(UtilityJob)
        .where(col(UtilityJob.organization_id) == ctx.organization.id)
        .order_by(func.lower(col(UtilityJob.name)).asc(), col(UtilityJob.created_at).asc())
    )
    return await paginate(session, statement)


@router.get("/script-options", response_model=list[UtilityJobScriptOption])
async def list_utility_job_script_options(
    ctx: OrganizationContext = ORG_MEMBER_DEP,
) -> list[UtilityJobScriptOption]:
    """List allowlisted utility scripts that jobs may schedule."""
    _ = ctx
    return [UtilityJobScriptOption.model_validate(item) for item in script_options()]


@router.post("", response_model=UtilityJobRead)
async def create_utility_job(
    payload: UtilityJobCreate,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> UtilityJobRead:
    """Create a utility job and enqueue crontab generation."""
    _validate_job_fields(
        cron_expression=payload.cron_expression,
        script_key=payload.script_key,
    )
    await _validate_scope(
        session,
        organization_id=ctx.organization.id,
        board_id=payload.board_id,
        agent_id=payload.agent_id,
    )
    job = await crud.create(
        session,
        UtilityJob,
        organization_id=ctx.organization.id,
        **payload.model_dump(),
    )
    enqueue_utility_job_crontab(job.id)
    return UtilityJobRead.model_validate(job, from_attributes=True)


@router.get("/{job_id}/logs", response_model=list[str])
async def get_utility_job_logs(
    job_id: UUID,
    limit: int = Query(10, ge=1, le=100),
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_MEMBER_DEP,
) -> list[str]:
    """Get recent log entries for a utility job."""
    job = await _require_org_job(session, job_id=job_id, ctx=ctx)
    log_dir = Path(LOG_DIR)
    prefix = f"job-{str(job.id)[:8]}."
    log_files = []
    if log_dir.exists():
        for entry in log_dir.iterdir():
            if entry.is_file() and entry.name.startswith(prefix) and entry.name.endswith(".log"):
                log_files.append(entry)
    if not log_files:
        return []
    log_files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    latest_file = log_files[0]
    try:
        with latest_file.open("r", encoding="utf-8") as f:
            lines = f.readlines()
            return [line.rstrip("\n") for line in lines[-limit:]]
    except Exception:
        return []


@router.get("/{job_id}", response_model=UtilityJobRead)
async def get_utility_job(
    job_id: UUID,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_MEMBER_DEP,
) -> UtilityJobRead:
    """Get a single utility job."""
    job = await _require_org_job(session, job_id=job_id, ctx=ctx)
    return UtilityJobRead.model_validate(job, from_attributes=True)


@router.patch("/{job_id}", response_model=UtilityJobRead)
async def update_utility_job(
    job_id: UUID,
    payload: UtilityJobUpdate,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> UtilityJobRead:
    """Update a utility job and enqueue crontab regeneration."""
    job = await _require_org_job(session, job_id=job_id, ctx=ctx)
    updates = payload.model_dump(exclude_unset=True)
    next_cron = str(updates.get("cron_expression") or job.cron_expression)
    next_script = str(updates.get("script_key") or job.script_key)
    _validate_job_fields(cron_expression=next_cron, script_key=next_script)

    next_board_id = updates.get("board_id", job.board_id)
    next_agent_id = updates.get("agent_id", job.agent_id)
    await _validate_scope(
        session,
        organization_id=ctx.organization.id,
        board_id=next_board_id if isinstance(next_board_id, UUID) else None,
        agent_id=next_agent_id if isinstance(next_agent_id, UUID) else None,
    )
    updates["updated_at"] = utcnow()
    updated = await crud.patch(session, job, updates)
    enqueue_utility_job_crontab(updated.id)
    return UtilityJobRead.model_validate(updated, from_attributes=True)


@router.delete("/{job_id}", response_model=OkResponse)
async def delete_utility_job(
    job_id: UUID,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> OkResponse:
    """Delete a utility job and enqueue crontab cleanup."""
    job = await _require_org_job(session, job_id=job_id, ctx=ctx)
    await crud.delete(session, job)
    enqueue_utility_job_crontab(job_id, action="delete")
    return OkResponse()
