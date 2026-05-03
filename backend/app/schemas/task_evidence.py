"""Schemas for task evidence packets, artifacts, and checks."""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import field_validator
from sqlmodel import Field, SQLModel

TaskClass = Literal[
    "code_deterministic",
    "design_exploratory",
    "ops_integration",
    "docs_content",
    "component_test",
    "workspace_config",
]
TaskClosureMode = Literal["manual_review", "evidence_packet", "passing_checks"]
TaskEvidencePacketStatus = Literal["draft", "submitted", "accepted", "rejected"]
TaskEvidenceCheckStatus = Literal["passed", "failed", "not_run"]

RUNTIME_ANNOTATION_TYPES = (datetime, UUID)


def _normalize_kind_list(values: list[str] | None) -> list[str]:
    if not values:
        return []
    normalized: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized_value = value.strip().lower()
        if not normalized_value or normalized_value in seen:
            continue
        seen.add(normalized_value)
        normalized.append(normalized_value)
    return normalized


class TaskEvidenceArtifactBase(SQLModel):
    """Shared artifact fields used by create/read payloads."""

    kind: str
    label: str
    workspace_agent_id: UUID | None = None
    workspace_agent_name: str | None = None
    workspace_root_key: str | None = None
    relative_path: str | None = None
    display_path: str | None = None
    origin_kind: str | None = None
    is_primary: bool = False

    @field_validator("kind", "origin_kind", mode="before")
    @classmethod
    def normalize_string_fields(cls, value: object) -> object:
        if value is None:
            return None
        if isinstance(value, str):
            normalized = value.strip().lower()
            return normalized or None
        return value


class TaskEvidenceArtifactCreate(TaskEvidenceArtifactBase):
    """Artifact payload declared when creating a packet."""


class TaskEvidenceArtifactRead(TaskEvidenceArtifactBase):
    """Artifact payload returned when reading a packet."""

    id: UUID
    packet_id: UUID
    task_id: UUID
    created_at: datetime


class TaskEvidenceCheckBase(SQLModel):
    """Shared verification-check fields used by create/read payloads."""

    kind: str
    label: str
    status: TaskEvidenceCheckStatus = "not_run"
    command: str | None = None
    result_summary: str | None = None

    @field_validator("kind", mode="before")
    @classmethod
    def normalize_kind(cls, value: object) -> object:
        if isinstance(value, str):
            normalized = value.strip().lower()
            return normalized or value
        return value


class TaskEvidenceCheckCreate(TaskEvidenceCheckBase):
    """Check payload declared when creating a packet."""


class TaskEvidenceCheckRead(TaskEvidenceCheckBase):
    """Check payload returned when reading a packet."""

    id: UUID
    packet_id: UUID
    task_id: UUID
    created_at: datetime


class TaskEvidencePacketCreate(SQLModel):
    """Payload used to create a task evidence packet."""

    task_class: TaskClass | None = None
    status: TaskEvidencePacketStatus = "submitted"
    summary: str | None = None
    implementation_delta: str | None = None
    review_notes: str | None = None
    artifacts: list[TaskEvidenceArtifactCreate] = Field(default_factory=list)
    checks: list[TaskEvidenceCheckCreate] = Field(default_factory=list)


class TaskEvidencePacketRead(SQLModel):
    """Evidence packet payload returned to the UI and automation."""

    id: UUID
    board_id: UUID
    task_id: UUID
    created_by_agent_id: UUID | None = None
    created_by_user_id: UUID | None = None
    task_class: TaskClass | None = None
    status: TaskEvidencePacketStatus
    summary: str | None = None
    implementation_delta: str | None = None
    review_notes: str | None = None
    primary_artifact_id: UUID | None = None
    primary_artifact: TaskEvidenceArtifactRead | None = None
    artifacts: list[TaskEvidenceArtifactRead] = Field(default_factory=list)
    checks: list[TaskEvidenceCheckRead] = Field(default_factory=list)
    submitted_at: datetime | None = None
    reviewed_at: datetime | None = None
    reviewed_by_agent_id: UUID | None = None
    reviewed_by_user_id: UUID | None = None
    created_at: datetime
    updated_at: datetime


class TaskClosureMetadata(SQLModel):
    """Structured task closure metadata surfaced on task read/write payloads."""

    task_class: TaskClass | None = None
    closure_mode: TaskClosureMode | None = None
    required_artifact_kinds: list[str] = Field(default_factory=list)
    required_check_kinds: list[str] = Field(default_factory=list)
    lead_spot_check_required: bool = False

    @field_validator("required_artifact_kinds", "required_check_kinds", mode="before")
    @classmethod
    def normalize_required_kind_lists(cls, value: object) -> object:
        if value is None:
            return []
        if isinstance(value, list):
            return _normalize_kind_list(
                [item for item in value if isinstance(item, str)],
            )
        return value
