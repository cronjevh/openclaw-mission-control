"""Schemas for GUI-managed utility cron jobs."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Self
from uuid import UUID

from pydantic import field_validator, model_validator
from sqlmodel import Field, SQLModel

_ERR_NAME_REQUIRED = "Job name is required"
_ERR_CRON_REQUIRED = "Cron expression is required"
_ERR_SCRIPT_REQUIRED = "Script key is required"


def _normalize_text(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = value.strip()
    return normalized or None


class UtilityJobBase(SQLModel):
    """Shared utility job fields."""

    name: str
    description: str | None = None
    enabled: bool = True
    board_id: UUID | None = None
    agent_id: UUID | None = None
    cron_expression: str = Field(
        description="Five-field cron expression, e.g. '0 8 * * *'.",
    )
    script_key: str
    args: dict[str, Any] | None = None

    @field_validator("name", "cron_expression", "script_key")
    @classmethod
    def _strip_required(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("Field is required")
        return normalized

    @field_validator("description")
    @classmethod
    def _strip_optional(cls, value: str | None) -> str | None:
        return _normalize_text(value)

    @model_validator(mode="after")
    def _validate_required_messages(self) -> Self:
        if not self.name.strip():
            raise ValueError(_ERR_NAME_REQUIRED)
        if not self.cron_expression.strip():
            raise ValueError(_ERR_CRON_REQUIRED)
        if not self.script_key.strip():
            raise ValueError(_ERR_SCRIPT_REQUIRED)
        return self


class UtilityJobCreate(UtilityJobBase):
    """Payload for creating a utility job."""


class UtilityJobUpdate(SQLModel):
    """Payload for updating a utility job."""

    name: str | None = None
    description: str | None = None
    enabled: bool | None = None
    board_id: UUID | None = None
    agent_id: UUID | None = None
    cron_expression: str | None = None
    script_key: str | None = None
    args: dict[str, Any] | None = None

    @field_validator("name", "cron_expression", "script_key")
    @classmethod
    def _strip_required(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        if not normalized:
            raise ValueError("Field cannot be blank")
        return normalized

    @field_validator("description")
    @classmethod
    def _strip_optional(cls, value: str | None) -> str | None:
        return _normalize_text(value)


class UtilityJobRead(UtilityJobBase):
    """Utility job returned by read endpoints."""

    id: UUID
    organization_id: UUID
    crontab_path: str | None = None
    last_generated_at: datetime | None = None
    created_at: datetime
    updated_at: datetime


class UtilityJobScriptOption(SQLModel):
    """Allowlisted script option exposed to the frontend."""

    key: str
    label: str
    description: str | None = None
