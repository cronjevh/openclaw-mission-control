"""Pydantic/SQLModel schemas for agent schedule API payloads."""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import Field, field_validator
from sqlmodel import SQLModel
from sqlmodel._compat import SQLModelConfig

from app.schemas.common import NonEmptyStr

# Allowed interval values (whitelist to prevent abuse)
VALID_INTERVALS = {1, 2, 5, 10, 15, 30, 60}


class AgentScheduleBase(SQLModel):
    """Common fields for agent schedule create/update payloads."""

    model_config = SQLModelConfig(
        json_schema_extra={
            "x-llm-intent": "agent_schedule_management",
            "x-when-to-use": [
                "View or modify an agent's heartbeat schedule",
                "Configure per-agent cron intervals for Mission Control",
            ],
            "x-when-not-to-use": [
                "Modifying system crontab directly (use OS tools)",
                "One-off heartbeat triggers (use /heartbeat endpoint)",
            ],
            "x-required-actor": "agent_self_or_board_lead",
            "x-prerequisites": [
                "Agent must belong to the board being accessed",
                "Board lead role required for cross-agent modifications",
            ],
            "x-side-effects": [
                "Changes affect cron scheduling for the target agent",
                "Updates are persisted and audited via last_updated_by",
            ],
        },
    )

    interval_minutes: int = Field(
        default=5,
        ge=1,
        le=60,
        description="Heartbeat interval in minutes (whitelisted values only)",
        examples=[5],
    )
    enabled: bool = Field(
        default=True,
        description="Whether the schedule is active",
    )

    @field_validator("interval_minutes")
    @classmethod
    def validate_interval(cls, v: int) -> int:
        if v not in VALID_INTERVALS:
            raise ValueError(
                f"Invalid interval {v}. Must be one of: {sorted(VALID_INTERVALS)} minutes"
            )
        return v


class AgentScheduleCreate(AgentScheduleBase):
    """Payload for creating a new agent schedule (not used directly — PATCH updates only)."""

    pass


class AgentScheduleUpdate(AgentScheduleBase):
    """Payload for updating an existing agent schedule."""

    pass


class AgentScheduleRead(SQLModel):
    """Response schema for agent schedule retrieval."""

    model_config = SQLModelConfig(from_attributes=True)

    id: UUID
    agent_id: UUID
    board_id: UUID
    interval_minutes: int
    cron_expression: str
    enabled: bool
    last_updated_by: UUID
    updated_at: datetime
    version: int


class AgentScheduleBulkRead(SQLModel):
    """Response containing all agent schedules for a board (lead-only)."""

    model_config = SQLModelConfig(from_attributes=True)

    schedules: list[AgentScheduleRead]
