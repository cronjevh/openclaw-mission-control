from __future__ import annotations

import asyncio
from typing import Any, cast
from uuid import uuid4

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine
from sqlmodel import SQLModel, col, select
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api import tasks as tasks_api
from app.api.deps import ActorContext
from app.models.activity_events import ActivityEvent
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.organizations import Organization
from app.models.tasks import Task


async def _make_engine() -> AsyncEngine:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn, conn.begin():
        await conn.run_sync(SQLModel.metadata.create_all)
    return engine


async def _make_session(engine: AsyncEngine) -> AsyncSession:
    return AsyncSession(engine, expire_on_commit=False)


@pytest.mark.asyncio
async def test_task_comment_fallback_mirrors_session_reply() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            org_id = uuid4()
            gateway_id = uuid4()
            board_id = uuid4()
            agent_id = uuid4()
            task_id = uuid4()

            session.add(Organization(id=org_id, name="org"))
            session.add(
                Gateway(
                    id=gateway_id,
                    organization_id=org_id,
                    name="gateway",
                    url="https://gateway.local",
                    workspace_root="/tmp/workspace",
                ),
            )
            session.add(
                Board(
                    id=board_id,
                    organization_id=org_id,
                    name="board",
                    slug="board",
                    gateway_id=gateway_id,
                ),
            )
            session.add(
                Agent(
                    id=agent_id,
                    name="Atlas",
                    board_id=board_id,
                    gateway_id=gateway_id,
                    openclaw_session_id="agent:lead:main",
                    status="online",
                    is_board_lead=True,
                ),
            )
            session.add(
                Task(
                    id=task_id,
                    board_id=board_id,
                    title="Blocked task",
                    description="",
                    status="blocked",
                ),
            )
            await session.commit()

            local_session_maker = async_sessionmaker(
                engine,
                expire_on_commit=False,
                class_=AsyncSession,
            )

            async def fake_openclaw_call(
                method: str, params: dict[str, Any], *, config: object
            ) -> dict:
                assert method == "chat.history"
                assert params["sessionKey"] == "agent:lead:main"
                return {
                    "messages": [
                        {
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "text",
                                    "text": "Please restart the backend and then retry this task.",
                                }
                            ],
                            "__openclaw": {"seq": 11},
                        }
                    ]
                }

            monkeypatch = pytest.MonkeyPatch()
            monkeypatch.setattr(tasks_api, "async_session_maker", local_session_maker)
            monkeypatch.setattr(tasks_api, "openclaw_call", fake_openclaw_call)
            try:
                await tasks_api._mirror_session_reply_to_task_comment(
                    task_id=task_id,
                    board_id=board_id,
                    agent_id=agent_id,
                    session_key="agent:lead:main",
                    config=cast(Any, object()),
                    after_seq=10,
                )
                await tasks_api._mirror_session_reply_to_task_comment(
                    task_id=task_id,
                    board_id=board_id,
                    agent_id=agent_id,
                    session_key="agent:lead:main",
                    config=cast(Any, object()),
                    after_seq=10,
                )
            finally:
                monkeypatch.undo()

            rows = list(
                await session.exec(
                    select(ActivityEvent)
                    .where(col(ActivityEvent.task_id) == task_id)
                    .where(col(ActivityEvent.event_type) == "task.comment")
                )
            )
            assert len(rows) == 1
            assert rows[0].agent_id == agent_id
            assert rows[0].message == "Please restart the backend and then retry this task."
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_task_comment_notifications_schedule_session_reply_fallback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            org_id = uuid4()
            gateway_id = uuid4()
            board_id = uuid4()
            actor_id = uuid4()
            lead_id = uuid4()
            task_id = uuid4()

            session.add(Organization(id=org_id, name="org"))
            session.add(
                Gateway(
                    id=gateway_id,
                    organization_id=org_id,
                    name="gateway",
                    url="https://gateway.local",
                    workspace_root="/tmp/workspace",
                ),
            )
            session.add(
                Board(
                    id=board_id,
                    organization_id=org_id,
                    name="Mission Control Management",
                    slug="mission-control-management",
                    gateway_id=gateway_id,
                ),
            )
            actor = Agent(
                id=actor_id,
                name="Worker",
                board_id=board_id,
                gateway_id=gateway_id,
                status="online",
            )
            lead = Agent(
                id=lead_id,
                name="Atlas",
                board_id=board_id,
                gateway_id=gateway_id,
                openclaw_session_id="agent:lead:main",
                status="online",
                is_board_lead=True,
            )
            task = Task(
                id=task_id,
                board_id=board_id,
                title="Blocked task",
                description="",
                status="blocked",
            )
            session.add(actor)
            session.add(lead)
            session.add(task)
            await session.commit()

            async def fake_optional_gateway_config_for_board(self: object, board: Board) -> object:
                return object()

            async def fake_send_agent_task_message(**kwargs: Any) -> None:
                return None

            async def fake_baseline_session_seq(**kwargs: Any) -> int:
                return 41

            captured: list[dict[str, Any]] = []

            async def fake_mirror_session_reply_to_task_comment(**kwargs: Any) -> None:
                captured.append(kwargs)

            monkeypatch.setattr(
                tasks_api.GatewayDispatchService,
                "optional_gateway_config_for_board",
                fake_optional_gateway_config_for_board,
            )
            monkeypatch.setattr(tasks_api, "_send_agent_task_message", fake_send_agent_task_message)
            monkeypatch.setattr(tasks_api, "_baseline_session_seq", fake_baseline_session_seq)
            monkeypatch.setattr(
                tasks_api,
                "_mirror_session_reply_to_task_comment",
                fake_mirror_session_reply_to_task_comment,
            )

            await tasks_api._notify_task_comment_targets(
                session,
                request=tasks_api._TaskCommentNotifyRequest(
                    task=task,
                    actor=ActorContext(actor_type="agent", agent=actor),
                    message="@lead What can I do to help get this unblocked?",
                    targets={lead.id: lead},
                    mention_names={"lead"},
                ),
            )
            await asyncio.sleep(0)

            assert len(captured) == 1
            assert captured[0]["task_id"] == task_id
            assert captured[0]["board_id"] == board_id
            assert captured[0]["agent_id"] == lead_id
            assert captured[0]["session_key"] == "agent:lead:main"
            assert captured[0]["after_seq"] == 41
    finally:
        await engine.dispose()
