"""Utility job definitions for GUI-managed deterministic cron tasks."""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import JSON, Column, Text
from sqlmodel import Field

from app.core.time import utcnow
from app.models.tenancy import TenantScoped

RUNTIME_ANNOTATION_TYPES = (datetime,)


class UtilityJob(TenantScoped, table=True):
    """Organization-scoped utility job scheduled through generated cron files."""

    __tablename__ = "utility_jobs"  # pyright: ignore[reportAssignmentType]

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    organization_id: UUID = Field(foreign_key="organizations.id", index=True)
    board_id: UUID | None = Field(default=None, foreign_key="boards.id", index=True)
    agent_id: UUID | None = Field(default=None, foreign_key="agents.id", index=True)
    name: str = Field(index=True)
    description: str | None = Field(default=None, sa_column=Column(Text))
    enabled: bool = Field(default=True, index=True)
    cron_expression: str
    script_key: str = Field(index=True)
    args: dict[str, Any] | None = Field(default=None, sa_column=Column(JSON))
    crontab_path: str | None = None
    last_generated_at: datetime | None = None
    created_at: datetime = Field(default_factory=utcnow)
    updated_at: datetime = Field(default_factory=utcnow)
