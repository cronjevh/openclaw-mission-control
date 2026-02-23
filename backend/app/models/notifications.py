"""Notification model for user-scoped in-app alerts."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlmodel import Field

from app.core.time import utcnow
from app.models.base import QueryModel

RUNTIME_ANNOTATION_TYPES = (datetime,)


class Notification(QueryModel, table=True):
    """User notification record created on relevant task events."""

    __tablename__ = "notifications"  # pyright: ignore[reportAssignmentType]

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    org_id: UUID = Field(foreign_key="organizations.id", index=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    board_id: UUID | None = Field(default=None, foreign_key="boards.id", index=True)
    task_id: UUID | None = Field(default=None, foreign_key="tasks.id")
    # type: status_changed | comment_added | mention
    type: str
    title: str
    body: str
    read: bool = Field(default=False)
    created_at: datetime = Field(default_factory=utcnow)
