"""Helpers for creating user notifications on task events."""

from __future__ import annotations

import re
from typing import TYPE_CHECKING
from uuid import UUID

if TYPE_CHECKING:
    from sqlmodel.ext.asyncio.session import AsyncSession

from app.models.notifications import Notification

# Matches @word or @word-with-dashes (as normalised by the frontend)
_MENTION_RE = re.compile(r"@([A-Za-z][A-Za-z0-9_-]*)", re.UNICODE)


def extract_user_mention_names(text: str) -> list[str]:
    """Return lowercase mention tokens found in *text*."""
    return [m.lower() for m in _MENTION_RE.findall(text)]


async def create_user_notification(
    session: AsyncSession,
    *,
    user_id: UUID,
    org_id: UUID,
    board_id: UUID | None,
    task_id: UUID | None,
    type: str,
    title: str,
    body: str,
) -> None:
    """Append a notification row; caller must commit."""
    notif = Notification(
        user_id=user_id,
        org_id=org_id,
        board_id=board_id,
        task_id=task_id,
        type=type,
        title=title,
        body=body,
    )
    session.add(notif)
