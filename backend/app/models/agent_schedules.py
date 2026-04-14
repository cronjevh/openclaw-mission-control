"""Agent heartbeat schedule model for per-agent crontab management."""

from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import JSON, Column, Integer, Text
from sqlmodel import Field, Relationship

from app.core.time import utcnow
from app.models.base import QueryModel


class AgentSchedule(QueryModel, table=True):
    """Per-agent heartbeat schedule configuration.

    This table replaces system crontab entries with agent-owned schedules.
    Each agent can have exactly one active schedule (one-to-one with agents).
    """

    __tablename__ = "agent_schedules"  # pyright: ignore[reportAssignmentType]

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    agent_id: UUID = Field(
        foreign_key="agents.id",
        unique=True,
        index=True,
        description="Agent this schedule belongs to (one-to-one)",
    )
    board_id: UUID = Field(
        foreign_key="boards.id",
        index=True,
        description="Board scope for permission checks",
    )
    interval_minutes: int = Field(
        index=True,
        description="Heartbeat interval in minutes (whitelist: 1,2,5,10,15,30,60)",
    )
    cron_expression: str = Field(
        sa_column=Column(Text),
        description="Generated cron expression (e.g., '*/5 * * * *')",
    )
    enabled: bool = Field(
        default=True,
        index=True,
        description="Whether this schedule is active",
    )
    last_updated_by: UUID = Field(
        foreign_key="agents.id",
        description="Agent or user who last modified this schedule",
    )
    updated_at: datetime = Field(default_factory=utcnow)
    version: int = Field(
        default=0,
        description="Optimistic locking version",
    )

    # Relationships (optional, for convenience)
    agent: list["Agent"] = Relationship(
        back_populates="schedule",
        sa_relationship_kwargs={"foreign_keys": "[AgentSchedule.agent_id]"},
    )
    # board: "Board" = Relationship(back_populates="agent_schedules")  # optional
