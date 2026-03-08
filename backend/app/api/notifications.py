"""Notifications API: list, mark-read, and SSE stream for the current user."""

from __future__ import annotations

import asyncio
import json
from collections import deque
from datetime import UTC, datetime
from typing import TYPE_CHECKING
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import desc
from sqlmodel import col, select
from sse_starlette.sse import EventSourceResponse

from app.api.deps import require_user_auth
from app.core.auth import AuthContext
from app.core.time import utcnow
from app.db.session import async_session_maker, get_session
from app.models.notifications import Notification
from app.schemas.common import OkResponse

if TYPE_CHECKING:
    from collections.abc import AsyncIterator

    from sqlmodel.ext.asyncio.session import AsyncSession

router = APIRouter(prefix="/notifications", tags=["notifications"])

SESSION_DEP = Depends(get_session)
AUTH_DEP = Depends(require_user_auth)
SINCE_QUERY = Query(default=None)
LIMIT_QUERY = Query(default=40, ge=1, le=100)

SSE_SEEN_MAX = 500
STREAM_POLL_SECONDS = 3


def _parse_since(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is not None:
        return parsed.astimezone(UTC).replace(tzinfo=None)
    return parsed


def _notif_payload(n: Notification) -> dict[str, object]:
    return {
        "id": str(n.id),
        "type": n.type,
        "title": n.title,
        "body": n.body,
        "read": n.read,
        "board_id": str(n.board_id) if n.board_id else None,
        "task_id": str(n.task_id) if n.task_id else None,
        "created_at": n.created_at.isoformat() + "Z",
    }


@router.get("")
async def list_notifications(
    session: AsyncSession = SESSION_DEP,
    auth: AuthContext = AUTH_DEP,
    limit: int = LIMIT_QUERY,
) -> list[dict[str, object]]:
    """Return the most recent notifications for the current user."""
    if auth.user is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    rows = await session.exec(
        select(Notification)
        .where(col(Notification.user_id) == auth.user.id)
        .order_by(desc(col(Notification.created_at)))
        .limit(limit)
    )
    return [_notif_payload(n) for n in rows.all()]


@router.get("/unread-count")
async def unread_count(
    session: AsyncSession = SESSION_DEP,
    auth: AuthContext = AUTH_DEP,
) -> dict[str, int]:
    """Return the unread notification count for the current user."""
    if auth.user is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    rows = await session.exec(
        select(Notification)
        .where(col(Notification.user_id) == auth.user.id)
        .where(col(Notification.read) == False)  # noqa: E712
    )
    return {"count": len(rows.all())}


@router.patch("/read-all", response_model=OkResponse)
async def mark_all_read(
    session: AsyncSession = SESSION_DEP,
    auth: AuthContext = AUTH_DEP,
) -> OkResponse:
    """Mark all notifications as read for the current user."""
    if auth.user is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    rows = await session.exec(
        select(Notification)
        .where(col(Notification.user_id) == auth.user.id)
        .where(col(Notification.read) == False)  # noqa: E712
    )
    for n in rows.all():
        n.read = True
        session.add(n)
    await session.commit()
    return OkResponse()


@router.patch("/{notification_id}/read", response_model=OkResponse)
async def mark_one_read(
    notification_id: UUID,
    session: AsyncSession = SESSION_DEP,
    auth: AuthContext = AUTH_DEP,
) -> OkResponse:
    """Mark a single notification as read."""
    if auth.user is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    n = await session.get(Notification, notification_id)
    if n is None or n.user_id != auth.user.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    n.read = True
    session.add(n)
    await session.commit()
    return OkResponse()


async def _notification_stream_generator(
    request: Request,
    *,
    user_id: UUID,
    since_dt: datetime,
) -> AsyncIterator[dict[str, str]]:
    last_seen = since_dt
    seen_ids: set[UUID] = set()
    seen_queue: deque[UUID] = deque()

    while True:
        if await request.is_disconnected():
            break

        async with async_session_maker() as session:
            rows = await session.exec(
                select(Notification)
                .where(col(Notification.user_id) == user_id)
                .where(col(Notification.created_at) >= last_seen)
                .order_by(col(Notification.created_at))
            )
            new_notifs = rows.all()

        for n in new_notifs:
            if n.id in seen_ids:
                continue
            seen_ids.add(n.id)
            seen_queue.append(n.id)
            if len(seen_queue) > SSE_SEEN_MAX:
                oldest = seen_queue.popleft()
                seen_ids.discard(oldest)
            last_seen = max(n.created_at, last_seen)
            yield {"event": "notification", "data": json.dumps(_notif_payload(n))}

        await asyncio.sleep(STREAM_POLL_SECONDS)


@router.get("/stream")
async def stream_notifications(
    request: Request,
    since: str | None = SINCE_QUERY,
    session: AsyncSession = SESSION_DEP,
    auth: AuthContext = AUTH_DEP,
) -> EventSourceResponse:
    """SSE stream of new notifications for the current user."""
    if auth.user is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    since_dt = _parse_since(since) or utcnow()
    return EventSourceResponse(
        _notification_stream_generator(
            request,
            user_id=auth.user.id,
            since_dt=since_dt,
        ),
        ping=15,
    )
