"""Organization-wide search API: tasks and comments scoped to user's accessible boards."""

from __future__ import annotations

from typing import TYPE_CHECKING

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func
from sqlmodel import col, select

from app.api.deps import ORG_MEMBER_DEP, OrganizationContext
from app.db.session import get_session
from app.models.activity_events import ActivityEvent
from app.models.boards import Board
from app.models.tasks import Task
from app.services.organizations import list_accessible_board_ids


if TYPE_CHECKING:
    from sqlmodel.ext.asyncio.session import AsyncSession

router = APIRouter(prefix="/search", tags=["search"])

SESSION_DEP = Depends(get_session)
Q_QUERY = Query(default="", min_length=0)
LIMIT = 30


@router.get("")
async def global_search(
    q: str = Q_QUERY,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_MEMBER_DEP,
) -> dict[str, object]:
    """
    Search tasks (title + description) and comments across all boards
    the current user has read access to within their organization.
    """
    q = q.strip()
    if not q:
        return {"tasks": [], "comments": []}

    # Get all board ids the user can read
    accessible_ids = await list_accessible_board_ids(
        session, member=ctx.member, write=False,
    )
    if not accessible_ids:
        return {"tasks": [], "comments": []}

    pattern = f"%{q}%"

    # --- Tasks: match title or description ---
    task_stmt = (
        select(Task, Board.name)
        .join(Board, col(Task.board_id) == col(Board.id))
        .where(col(Task.board_id).in_(accessible_ids))
        .where(
            col(Task.title).ilike(pattern)
            | col(Task.description).ilike(pattern)
        )
        .order_by(col(Task.created_at).desc())
        .limit(LIMIT)
    )
    task_rows = list(await session.exec(task_stmt))

    # --- Comments: match message ---
    comment_stmt = (
        select(ActivityEvent, Task, Board.name)
        .join(Task, col(ActivityEvent.task_id) == col(Task.id))
        .join(Board, col(Task.board_id) == col(Board.id))
        .where(col(Task.board_id).in_(accessible_ids))
        .where(col(ActivityEvent.event_type) == "task.comment")
        .where(func.length(func.trim(col(ActivityEvent.message))) > 0)
        .where(col(ActivityEvent.message).ilike(pattern))
        .order_by(col(ActivityEvent.created_at).desc())
        .limit(LIMIT)
    )
    comment_rows = list(await session.exec(comment_stmt))

    tasks_out = []
    for row in task_rows:
        task, board_name = row[0], row[1]
        tasks_out.append(
            {
                "id": str(task.id),
                "title": task.title,
                "status": task.status,
                "description": task.description,
                "board_id": str(task.board_id) if task.board_id else None,
                "board_name": board_name,
            }
        )

    comments_out = []
    for row in comment_rows:
        event, task, board_name = row[0], row[1], row[2]
        comments_out.append(
            {
                "id": str(event.id),
                "message": event.message,
                "author_name": event.author_name,
                "created_at": event.created_at.isoformat() + "Z",
                "task_id": str(task.id),
                "task_title": task.title,
                "task_status": task.status,
                "board_id": str(task.board_id) if task.board_id else None,
                "board_name": board_name,
            }
        )

    return {"tasks": tasks_out, "comments": comments_out}
