from __future__ import annotations

from uuid import uuid4

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine
from sqlmodel import SQLModel, select
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api import agent as agent_api
from app.api import tasks as tasks_api
from app.core.agent_auth import AgentAuthContext
from app.core.auth import AuthContext
from app.models.activity_events import ActivityEvent
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.organizations import Organization
from app.models.tasks import Task
from app.schemas.tasks import TaskCreate, TaskUpdate


async def _make_engine() -> AsyncEngine:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn, conn.begin():
        await conn.run_sync(SQLModel.metadata.create_all)
    return engine


async def _make_session(engine: AsyncEngine) -> AsyncSession:
    return AsyncSession(engine, expire_on_commit=False)


async def _seed_board_and_lead(session: AsyncSession) -> tuple[Board, Agent]:
    organization_id = uuid4()
    gateway_id = uuid4()
    board = Board(
        id=uuid4(),
        organization_id=organization_id,
        gateway_id=gateway_id,
        name="board",
        slug=f"board-{uuid4()}",
        require_approval_for_done=False,
    )
    lead = Agent(
        id=uuid4(),
        board_id=board.id,
        gateway_id=gateway_id,
        name="Atlas",
        is_board_lead=True,
        status="online",
    )
    session.add(Organization(id=organization_id, name=f"org-{organization_id}"))
    session.add(
        Gateway(
            id=gateway_id,
            organization_id=organization_id,
            name="gateway",
            url="https://gateway.local",
            workspace_root="/tmp/workspace",
        )
    )
    session.add(board)
    session.add(lead)
    await session.commit()
    return board, lead


def _okr_payload(**overrides: object) -> TaskCreate:
    base = TaskCreate(
        title="Recover authoritative evidence enforcement and align task closure with OKRs",
        description=(
            "## Objective\n\n"
            "Recover evidence-backed task closure.\n\n"
            "## OKR Framing\n\n"
            "#### KR1\n\n"
            "Document the loophole.\n"
        ),
    )
    return base.model_copy(update=overrides)


@pytest.mark.asyncio
async def test_okr_task_defaults_to_evidence_packet_for_user_create() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board, _lead = await _seed_board_and_lead(session)

            created = await tasks_api.create_task(
                payload=_okr_payload(),
                board=board,
                session=session,
                auth=AuthContext(actor_type="user", user=None),
            )

            assert created.closure_mode == "evidence_packet"
            assert created.required_artifact_kinds == ["deliverable"]
            assert created.lead_spot_check_required is True
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_user_create_skips_lead_gateway_notification_when_auto_wake_disabled(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(tasks_api, "automatic_wake_reprovision_enabled", lambda: False)

    async def _unexpected_send_lead_task_message(**_: object) -> None:
        pytest.fail("task creation must not send lead gateway prompts while disabled")

    monkeypatch.setattr(
        tasks_api,
        "_send_lead_task_message",
        _unexpected_send_lead_task_message,
    )

    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board, lead = await _seed_board_and_lead(session)
            lead.openclaw_session_id = "lead-session"
            session.add(lead)
            await session.commit()

            await tasks_api.create_task(
                payload=TaskCreate(title="New manual task"),
                board=board,
                session=session,
                auth=AuthContext(actor_type="user", user=None),
            )

            events = (
                await session.exec(
                    select(ActivityEvent).where(
                        ActivityEvent.event_type.in_(
                            ["task.lead_notified", "task.lead_notify_failed"],
                        ),
                    ),
                )
            ).all()
            assert events == []
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_user_create_notifies_lead_when_auto_wake_enabled(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(tasks_api, "automatic_wake_reprovision_enabled", lambda: True)
    sent: list[dict[str, object]] = []

    async def _fake_send_lead_task_message(**kwargs: object) -> None:
        sent.append(kwargs)
        return None

    monkeypatch.setattr(
        tasks_api,
        "_send_lead_task_message",
        _fake_send_lead_task_message,
    )

    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board, lead = await _seed_board_and_lead(session)
            lead.openclaw_session_id = "lead-session"
            session.add(lead)
            await session.commit()

            await tasks_api.create_task(
                payload=TaskCreate(title="New manual task"),
                board=board,
                session=session,
                auth=AuthContext(actor_type="user", user=None),
            )

            assert len(sent) == 1
            assert sent[0]["session_key"] == "lead-session"
            assert "NEW TASK ADDED" in str(sent[0]["message"])
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_okr_task_defaults_to_evidence_packet_for_lead_agent_create() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board, lead = await _seed_board_and_lead(session)

            created = await agent_api.create_task(
                payload=_okr_payload(),
                board=board,
                session=session,
                agent_ctx=AgentAuthContext(actor_type="agent", agent=lead),
            )

            assert created.closure_mode == "evidence_packet"
            assert created.required_artifact_kinds == ["deliverable"]
            assert created.lead_spot_check_required is True
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_explicit_manual_review_is_preserved_for_okr_task() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board, _lead = await _seed_board_and_lead(session)

            created = await tasks_api.create_task(
                payload=_okr_payload(
                    closure_mode="manual_review",
                    required_artifact_kinds=[],
                    lead_spot_check_required=False,
                ),
                board=board,
                session=session,
                auth=AuthContext(actor_type="user", user=None),
            )

            assert created.closure_mode == "manual_review"
            assert created.required_artifact_kinds == []
            assert created.lead_spot_check_required is False
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_updating_task_to_okr_shape_backfills_evidence_defaults() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            board, _lead = await _seed_board_and_lead(session)

            created = await tasks_api.create_task(
                payload=TaskCreate(
                    title="Loose task that becomes OKR-shaped later",
                    description="Initial draft without explicit OKR framing.",
                ),
                board=board,
                session=session,
                auth=AuthContext(actor_type="user", user=None),
            )

            task = (
                await session.exec(select(Task).where(Task.id == created.id, Task.board_id == board.id))
            ).first()
            assert task is not None
            updated = await tasks_api.update_task(
                payload=TaskUpdate(description=_okr_payload().description),
                task=task,
                session=session,
                actor=AuthContext(actor_type="user", user=None),
            )

            assert updated.closure_mode == "evidence_packet"
            assert updated.required_artifact_kinds == ["deliverable"]
            assert updated.lead_spot_check_required is True
    finally:
        await engine.dispose()
