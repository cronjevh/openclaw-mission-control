"""Service layer for agent schedule management."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from sqlalchemy import select, update
from sqlmodel.ext.asyncio.session import AsyncSession

from app.models.agent_schedules import AgentSchedule
from app.models.agents import Agent
from app.schemas.agent_schedules import AgentScheduleRead

# Valid intervals in minutes (whitelist)
VALID_INTERVALS = {1, 2, 5, 10, 15, 30, 60}


def interval_to_cron(interval_minutes: int) -> str:
    """Convert an interval in minutes to a cron expression.

    Uses standard 5-field cron format: minute hour day month weekday
    Example: interval=5 -> "*/5 * * * *"
    """
    if interval_minutes not in VALID_INTERVALS:
        raise ValueError(f"Invalid interval {interval_minutes}. Must be one of {sorted(VALID_INTERVALS)}")

    return f"*/{interval_minutes} * * * *"


class AgentScheduleService:
    """Business logic for agent heartbeat scheduling."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_schedule(self, agent_id: UUID) -> AgentSchedule | None:
        """Fetch the schedule for a specific agent."""
        stmt = select(AgentSchedule).where(AgentSchedule.agent_id == agent_id)
        result = await self.session.exec(stmt)
        return result.first()

    async def get_schedule_by_agent(self, agent_id: UUID) -> AgentScheduleRead:
        """Get schedule for a specific agent (for GET endpoint)."""
        schedule = await self.get_schedule(agent_id)
        if schedule is None:
            # Return default schedule (5 min) if none exists yet
            # Caller should handle 404 if they need explicit existence
            raise ValueError(f"No schedule found for agent {agent_id}")
        return AgentScheduleRead.model_validate(schedule)

    async def list_board_schedules(self, board_id: UUID) -> list[AgentScheduleRead]:
        """List all agent schedules for a board (lead-only)."""
        stmt = select(AgentSchedule).where(AgentSchedule.board_id == board_id)
        result = await self.session.exec(stmt)
        schedules = list(result.all())
        return [AgentScheduleRead.model_validate(s) for s in schedules]

    async def create_or_update_schedule(
        self,
        agent_id: UUID,
        board_id: UUID,
        interval_minutes: int,
        enabled: bool,
        last_updated_by: UUID,
    ) -> AgentScheduleRead:
        """Create or update an agent's schedule.

        Uses upsert semantics: if a schedule exists for the agent, update it;
        otherwise create a new one.
        """
        if interval_minutes not in VALID_INTERVALS:
            raise ValueError(f"Invalid interval {interval_minutes}. Valid: {sorted(VALID_INTERVALS)}")

        cron_expr = interval_to_cron(interval_minutes)

        # Try to fetch existing schedule
        existing = await self.get_schedule(agent_id)

        if existing:
            # Update
            existing.interval_minutes = interval_minutes
            existing.cron_expression = cron_expr
            existing.enabled = enabled
            existing.last_updated_by = last_updated_by
            existing.updated_at = datetime.now(timezone.utc)
            existing.version += 1
            self.session.add(existing)
            await self.session.commit()
            await self.session.refresh(existing)
            schedule = existing
        else:
            # Create new
            schedule = AgentSchedule(
                agent_id=agent_id,
                board_id=board_id,
                interval_minutes=interval_minutes,
                cron_expression=cron_expr,
                enabled=enabled,
                last_updated_by=last_updated_by,
                updated_at=datetime.now(timezone.utc),
                version=0,
            )
            self.session.add(schedule)
            await self.session.commit()
            await self.session.refresh(schedule)

        return AgentScheduleRead.model_validate(schedule)

    async def delete_schedule(self, agent_id: UUID) -> bool:
        """Disable an agent's schedule (soft delete by disabling)."""
        stmt = (
            update(AgentSchedule)
            .where(AgentSchedule.agent_id == agent_id)
            .values(enabled=False, updated_at=datetime.now(timezone.utc))
        )
        result = await self.session.exec(stmt)
        await self.session.commit()
        return result.rowcount > 0
