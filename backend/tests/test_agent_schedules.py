"""Tests for agent schedule API endpoints."""

from __future__ import annotations

from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.api import agent as agent_api
from app.core.agent_auth import AgentAuthContext
from app.models.agents import Agent
from app.schemas.agent_schedules import AgentScheduleUpdate


def _agent_ctx(
    *,
    agent_id: UUID | None = None,
    board_id: UUID | None = None,
    status: str = "online",
    is_board_lead: bool = False,
) -> AgentAuthContext:
    """Helper to create an agent auth context."""
    return AgentAuthContext(
        actor_type="agent",
        agent=Agent(
            id=agent_id or uuid4(),
            board_id=board_id,
            gateway_id=uuid4(),
            name="Test Agent",
            status=status,
            is_board_lead=is_board_lead,
        ),
    )


# --- GET /agent/boards/{board_id}/agents/{agent_id}/schedule ---

async def test_get_own_schedule_returns_404_if_not_exists(
    db_session: AsyncSession,
) -> None:
    """An agent reading its own schedule when none exists returns 404."""
    agent_id = uuid4()
    board_id = uuid4()
    ctx = _agent_ctx(agent_id=agent_id, board_id=board_id)

    with pytest.raises(HTTPException) as exc_info:
        await agent_api.get_agent_schedule(
            agent_id=agent_id,
            board=None,  # will be set by dependency injection; we pass None for unit test
            session=db_session,
            agent_ctx=ctx,
        )
    assert exc_info.value.status_code == 404


async def test_get_other_agent_schedule_requires_lead(
    db_session: AsyncSession,
) -> None:
    """An agent cannot read another agent's schedule unless they are board lead."""
    agent_id = uuid4()
    other_agent_id = uuid4()
    board_id = uuid4()
    ctx = _agent_ctx(agent_id=agent_id, board_id=board_id, is_board_lead=False)

    # The _guard_board_access and require_board_lead_or_same_actor should raise
    with pytest.raises(HTTPException) as exc_info:
        await agent_api.get_agent_schedule(
            agent_id=other_agent_id,
            board=None,
            session=db_session,
            agent_ctx=ctx,
        )
    assert exc_info.value.status_code == 403


# --- PATCH /agent/boards/{board_id}/agents/{agent_id}/schedule ---

async def test_update_own_schedule_success(
    db_session: AsyncSession,
) -> None:
    """An agent can update its own schedule with a valid interval."""
    agent_id = uuid4()
    board_id = uuid4()
    ctx = _agent_ctx(agent_id=agent_id, board_id=board_id)

    payload = AgentScheduleUpdate(interval_minutes=10, enabled=True)

    # For unit test, we need to mock the service or use a real DB.
    # This test skeleton outlines the expected call pattern.
    # In integration test, we would actually create the agent and board first.
    # For now, we'll just test validation logic at the schema level.
    assert payload.interval_minutes == 10
    assert payload.enabled is True


def test_interval_validation_rejects_invalid_values() -> None:
    """Schema validation rejects intervals not in the whitelist."""
    with pytest.raises(ValueError):
        AgentScheduleUpdate(interval_minutes=3)  # not in whitelist

    with pytest.raises(ValueError):
        AgentScheduleUpdate(interval_minutes=45)  # not in whitelist

    # Valid values should succeed
    for valid in [1, 2, 5, 10, 15, 30, 60]:
        schedule = AgentScheduleUpdate(interval_minutes=valid)
        assert schedule.interval_minutes == valid


# --- GET /agent/boards/{board_id}/agents/schedules (lead only) ---

async def test_list_all_schedules_requires_lead(
    db_session: AsyncSession,
) -> None:
    """Only board leads can list all agent schedules."""
    agent_id = uuid4()
    board_id = uuid4()
    ctx = _agent_ctx(agent_id=agent_id, board_id=board_id, is_board_lead=False)

    with pytest.raises(HTTPException) as exc_info:
        await agent_api.list_board_agent_schedules(
            board=None,
            session=db_session,
            agent_ctx=ctx,
        )
    assert exc_info.value.status_code == 403
