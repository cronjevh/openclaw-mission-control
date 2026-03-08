"""Board-scoped search API: tasks and comments."""

from __future__ import annotations

from typing import TYPE_CHECKING
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func
from sqlmodel import col, select

from app.api.deps import require_user_auth
from app.core.auth import AuthContext
from app.db.session import get_session
from app.models.activity_events import ActivityEvent
from app.models.boards import Board
from app.models.tasks import Task
from app.services.organizations import require_board_access

if TYPE_CHECKING:
    from sqlmodel.ext.asyncio.session import AsyncSession

router = APIRouter(prefix="/boards/{board_id}/search", tags=["search"])

SESSION_DEP = Depends(get_session)
AUTH_DEP = Depends(require_user_auth)
Q_QUERY = Query(default="", min_length=0)
LIMIT = 20


@router.get("")
async def search_board(
    board_id: UUID,
    q: str = Q_QUERY,
    session: AsyncSession = SESSION_DEP,
    auth: AuthContext = AUTH_DEP,
) -> dict[str, object]:
    """
    Search tasks (title + description) and comments within a board.
    Returns up to 20 results per category.
    """
    if auth.user is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)

    board = await Board.objects.by_id(board_id).first(session)
    if board is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    await require_board_access(session, user=auth.user, board=board, write=False)

    q = q.strip()
    if not q:
        return {"tasks": [], "comments": []}

    pattern = f"%{q}%"

    # --- Tasks: match title or description ---
    task_stmt = (
        select(Task)
        .where(col(Task.board_id) == board_id)
        .where(
            col(Task.title).ilike(pattern)
            | col(Task.description).ilike(pattern)
        )
        .order_by(col(Task.created_at).desc())
        .limit(LIMIT)
    )
    task_rows = (await session.exec(task_stmt)).all()

    # --- Comments: match message ---
    comment_stmt = (
        select(ActivityEvent, Task)
        .join(Task, col(ActivityEvent.task_id) == col(Task.id))
        .where(col(Task.board_id) == board_id)
        .where(col(ActivityEvent.event_type) == "task.comment")
        .where(func.length(func.trim(col(ActivityEvent.message))) > 0)
        .where(col(ActivityEvent.message).ilike(pattern))
        .order_by(col(ActivityEvent.created_at).desc())
        .limit(LIMIT)
    )
    comment_rows = list(await session.exec(comment_stmt))

    tasks_out = [
        {
            "id": str(t.id),
            "title": t.title,
            "status": t.status,
            "description": t.description,
            "board_id": str(t.board_id) if t.board_id else None,
        }
        for t in task_rows
    ]

    comments_out = []
    for row in comment_rows:
        if isinstance(row, tuple):
            event, task = row
        else:
            continue
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
            }
        )

    return {"tasks": tasks_out, "comments": comments_out}
