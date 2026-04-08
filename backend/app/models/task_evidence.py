"""Task-linked evidence packet models used for review and closure."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlmodel import Field

from app.core.time import utcnow
from app.models.base import QueryModel

RUNTIME_ANNOTATION_TYPES = (datetime,)


class TaskEvidencePacket(QueryModel, table=True):
    """Canonical evidence packet attached to a task handoff."""

    __tablename__ = "task_evidence_packets"  # pyright: ignore[reportAssignmentType]

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    board_id: UUID = Field(foreign_key="boards.id", index=True)
    task_id: UUID = Field(foreign_key="tasks.id", index=True)
    created_by_agent_id: UUID | None = Field(
        default=None,
        foreign_key="agents.id",
        index=True,
    )
    created_by_user_id: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        index=True,
    )
    task_class: str | None = Field(default=None, index=True)
    status: str = Field(default="submitted", index=True)
    summary: str | None = None
    implementation_delta: str | None = None
    review_notes: str | None = None
    primary_artifact_id: UUID | None = Field(default=None, index=True)
    submitted_at: datetime | None = None
    reviewed_at: datetime | None = None
    reviewed_by_agent_id: UUID | None = Field(default=None, foreign_key="agents.id", index=True)
    reviewed_by_user_id: UUID | None = Field(default=None, foreign_key="users.id", index=True)
    created_at: datetime = Field(default_factory=utcnow)
    updated_at: datetime = Field(default_factory=utcnow)


class TaskEvidenceArtifact(QueryModel, table=True):
    """Artifact reference declared inside a task evidence packet."""

    __tablename__ = "task_evidence_artifacts"  # pyright: ignore[reportAssignmentType]

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    packet_id: UUID = Field(foreign_key="task_evidence_packets.id", index=True)
    task_id: UUID = Field(foreign_key="tasks.id", index=True)
    kind: str = Field(index=True)
    label: str
    workspace_agent_id: UUID | None = Field(
        default=None,
        foreign_key="agents.id",
        index=True,
    )
    workspace_agent_name: str | None = None
    workspace_root_key: str | None = Field(default=None, index=True)
    relative_path: str | None = None
    display_path: str | None = None
    origin_kind: str | None = Field(default=None, index=True)
    is_primary: bool = Field(default=False, index=True)
    created_at: datetime = Field(default_factory=utcnow)


class TaskEvidenceCheck(QueryModel, table=True):
    """Verification check attached to a task evidence packet."""

    __tablename__ = "task_evidence_checks"  # pyright: ignore[reportAssignmentType]

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    packet_id: UUID = Field(foreign_key="task_evidence_packets.id", index=True)
    task_id: UUID = Field(foreign_key="tasks.id", index=True)
    kind: str = Field(index=True)
    label: str
    status: str = Field(default="not_run", index=True)
    command: str | None = None
    result_summary: str | None = None
    created_at: datetime = Field(default_factory=utcnow)
