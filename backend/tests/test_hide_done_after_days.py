"""Tests for hide_done_after_days board configuration and task filtering."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api.tasks import _task_list_statement
from app.models.boards import Board
from app.models.tag_assignments import TagAssignment
from app.models.tags import Tag
from app.models.tasks import Task
from app.schemas.boards import BoardUpdate


async def _make_engine() -> AsyncEngine:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn, conn.begin():
        await conn.run_sync(SQLModel.metadata.create_all)
    return engine


async def _make_session(engine: AsyncEngine) -> AsyncSession:
    return AsyncSession(engine, expire_on_commit=False)


@pytest.mark.asyncio
async def test_task_list_statement_excludes_old_done_when_filter_set() -> None:
    """_task_list_statement applies hide_done_after_days filter correctly."""
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board_id = uuid4()
            board = Board(
                id=board_id,
                organization_id=uuid4(),
                name="Test Board",
                slug="test-board",
                hide_done_after_days=7,
            )
            session.add(board)
            now = datetime.now(timezone.utc)
            tasks = [
                Task(
                    board_id=board_id,
                    title="Old Done",
                    status="done",
                    updated_at=now - timedelta(days=10),
                ),
                Task(
                    board_id=board_id,
                    title="Recent Done",
                    status="done",
                    updated_at=now - timedelta(days=2),
                ),
                Task(
                    board_id=board_id,
                    title="In Progress",
                    status="in_progress",
                    updated_at=now,
                ),
            ]
            session.add_all(tasks)
            await session.commit()

            # Build statement with hide_done_after_days from board
            stmt = _task_list_statement(
                board_id=board_id,
                status_filter=None,
                assigned_agent_id=None,
                unassigned=None,
                hide_done_after_days=board.hide_done_after_days,
            )

            result = await session.exec(stmt)
            rows = result.all()
            titles = {t.title for t in rows}

            # Old Done should be excluded; others included
            assert "Old Done" not in titles
            assert "Recent Done" in titles
            assert "In Progress" in titles
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_task_list_statement_no_filter_when_null_or_zero() -> None:
    """hide_done_after_days=None or 0 means no extra filtering."""
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board_id = uuid4()
            board = Board(
                id=board_id,
                organization_id=uuid4(),
                name="Test Board",
                slug="test-board",
                hide_done_after_days=None,
            )
            session.add(board)
            now = datetime.now(timezone.utc)
            old_done = Task(
                board_id=board_id,
                title="Old Done",
                status="done",
                updated_at=now - timedelta(days=100),
            )
            session.add(old_done)
            await session.commit()

            # With None
            stmt_none = _task_list_statement(
                board_id=board_id,
                status_filter=None,
                assigned_agent_id=None,
                unassigned=None,
                hide_done_after_days=None,
            )
            rows_none = (await session.exec(stmt_none)).all()
            titles_none = {t.title for t in rows_none}
            assert "Old Done" in titles_none

            # With 0
            stmt_zero = _task_list_statement(
                board_id=board_id,
                status_filter=None,
                assigned_agent_id=None,
                unassigned=None,
                hide_done_after_days=0,
            )
            rows_zero = (await session.exec(stmt_zero)).all()
            titles_zero = {t.title for t in rows_zero}
            assert "Old Done" in titles_zero
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_task_list_statement_can_include_hidden_done_when_requested() -> None:
    """Explicit include_hidden_done bypasses the UI-oriented hide filter."""
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board_id = uuid4()
            board = Board(
                id=board_id,
                organization_id=uuid4(),
                name="Test Board",
                slug="test-board",
                hide_done_after_days=7,
            )
            session.add(board)
            now = datetime.now(timezone.utc)
            session.add(
                Task(
                    board_id=board_id,
                    title="Old Done",
                    status="done",
                    updated_at=now - timedelta(days=30),
                ),
            )
            await session.commit()

            stmt = _task_list_statement(
                board_id=board_id,
                status_filter=None,
                assigned_agent_id=None,
                unassigned=None,
                hide_done_after_days=board.hide_done_after_days,
                include_hidden_done=True,
            )

            rows = (await session.exec(stmt)).all()
            assert {task.title for task in rows} == {"Old Done"}
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_task_list_statement_filters_by_tag_slug_name_or_id() -> None:
    """Tag filters should match board tasks by slug, name, or UUID."""
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board_id = uuid4()
            organization_id = uuid4()
            board = Board(
                id=board_id,
                organization_id=organization_id,
                name="Test Board",
                slug="test-board",
            )
            release_tag = Tag(
                id=uuid4(),
                organization_id=organization_id,
                name="Release QA",
                slug="release-qa",
                color="111111",
            )
            backend_tag = Tag(
                id=uuid4(),
                organization_id=organization_id,
                name="Backend",
                slug="backend",
                color="222222",
            )
            release_task = Task(board_id=board_id, title="Release task", status="in_progress")
            backend_task = Task(board_id=board_id, title="Backend task", status="inbox")
            session.add_all([board, release_tag, backend_tag, release_task, backend_task])
            await session.flush()
            session.add_all(
                [
                    TagAssignment(task_id=release_task.id, tag_id=release_tag.id),
                    TagAssignment(task_id=backend_task.id, tag_id=backend_tag.id),
                ],
            )
            await session.commit()

            stmt_by_slug = _task_list_statement(
                board_id=board_id,
                status_filter=None,
                assigned_agent_id=None,
                unassigned=None,
                tag_filter="release-qa",
            )
            stmt_by_name = _task_list_statement(
                board_id=board_id,
                status_filter=None,
                assigned_agent_id=None,
                unassigned=None,
                tag_filter="Release QA",
            )
            stmt_by_id = _task_list_statement(
                board_id=board_id,
                status_filter=None,
                assigned_agent_id=None,
                unassigned=None,
                tag_filter=str(release_tag.id),
            )

            assert [(await session.exec(stmt_by_slug)).one().title] == ["Release task"]
            assert [(await session.exec(stmt_by_name)).one().title] == ["Release task"]
            assert [(await session.exec(stmt_by_id)).one().title] == ["Release task"]
    finally:
        await engine.dispose()


def test_board_update_schema_accepts_hide_done_after_days() -> None:
    """BoardUpdate should accept hide_done_after_days as optional int."""
    payload = {"hide_done_after_days": 30}
    update = BoardUpdate(**payload)
    assert update.hide_done_after_days == 30

    # Omitted field should be None
    update2 = BoardUpdate()
    assert update2.hide_done_after_days is None

    # Zero accepted
    update3 = BoardUpdate(hide_done_after_days=0)
    assert update3.hide_done_after_days == 0


@pytest.mark.asyncio
async def test_snapshot_uses_board_hide_done_after_days() -> None:
    """build_board_snapshot respects board.hide_done_after_days."""
    from app.services.board_snapshot import build_board_snapshot

    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board_id = uuid4()
            board = Board(
                id=board_id,
                organization_id=uuid4(),
                name="Test Board",
                slug="test-board",
                hide_done_after_days=7,
            )
            session.add(board)
            now = datetime.now(timezone.utc)
            tasks = [
                Task(
                    board_id=board_id,
                    title="Old Done",
                    status="done",
                    updated_at=now - timedelta(days=20),
                ),
                Task(
                    board_id=board_id,
                    title="Recent Done",
                    status="done",
                    updated_at=now - timedelta(hours=12),
                ),
                Task(
                    board_id=board_id,
                    title="In Progress",
                    status="in_progress",
                    updated_at=now,
                ),
            ]
            session.add_all(tasks)
            await session.commit()

            snapshot = await build_board_snapshot(session, board)
            task_titles = {t.title for t in snapshot.tasks}

            assert "Old Done" not in task_titles
            assert "Recent Done" in task_titles
            assert "In Progress" in task_titles
    finally:
        await engine.dispose()
