# ruff: noqa: INP001

from __future__ import annotations

from uuid import UUID, uuid4

import pytest
from fastapi import APIRouter, Depends, FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api import tasks as tasks_api
from app.api.agent import router as agent_router
from app.api.deps import get_board_or_404
from app.core import auth
from app.core.agent_tokens import hash_agent_token
from app.core.auth_mode import AuthMode
from app.db.session import get_session
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


def _build_test_app(session_maker: async_sessionmaker[AsyncSession]) -> FastAPI:
    app = FastAPI()
    api_v1 = APIRouter(prefix="/api/v1")
    api_v1.include_router(agent_router)
    app.include_router(api_v1)

    async def _override_get_session() -> AsyncSession:
        async with session_maker() as session:
            yield session

    async def _override_get_board_or_404(
        board_id: str,
        session: AsyncSession = Depends(get_session),
    ) -> Board:
        board = await Board.objects.by_id(UUID(board_id)).first(session)
        if board is None:
            from fastapi import HTTPException, status

            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        return board

    app.dependency_overrides[get_session] = _override_get_session
    app.dependency_overrides[get_board_or_404] = _override_get_board_or_404
    return app


async def _seed_task_update_fixture(
    session: AsyncSession,
    *,
    token: str,
) -> tuple[Board, Task, Agent]:
    organization_id = uuid4()
    gateway_id = uuid4()
    board_id = uuid4()
    lead_id = uuid4()
    worker_id = uuid4()
    task_id = uuid4()

    session.add(Organization(id=organization_id, name=f"org-{organization_id}"))
    session.add(
        Gateway(
            id=gateway_id,
            organization_id=organization_id,
            name="gateway",
            url="https://gateway.example.local",
            workspace_root="/tmp/workspace",
        ),
    )
    board = Board(
        id=board_id,
        organization_id=organization_id,
        gateway_id=gateway_id,
        name="Board",
        slug="board",
    )
    session.add(board)
    session.add(
        Agent(
            id=lead_id,
            board_id=board_id,
            gateway_id=gateway_id,
            name="Atlas",
            status="online",
            is_board_lead=True,
            agent_token_hash=hash_agent_token(token),
        ),
    )
    worker = Agent(
        id=worker_id,
        board_id=board_id,
        gateway_id=gateway_id,
        name="Worker",
        status="online",
    )
    session.add(worker)
    task = Task(
        id=task_id,
        board_id=board_id,
        title="Inbox task",
        description="ready for assignment",
        status="inbox",
        assigned_agent_id=None,
    )
    session.add(task)
    await session.commit()
    return board, task, worker


@pytest.mark.asyncio
async def test_agent_task_patch_uses_agent_scoped_task_lookup_when_authorization_header_overlaps_local_auth(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    token = "shared-local-and-agent-token"
    monkeypatch.setattr(auth.settings, "auth_mode", AuthMode.LOCAL)
    monkeypatch.setattr(auth.settings, "local_auth_token", token)

    async def _fake_notify_agent_on_task_assign(**_: object) -> None:
        return None

    monkeypatch.setattr(tasks_api, "_notify_agent_on_task_assign", _fake_notify_agent_on_task_assign)

    engine = await _make_engine()
    session_maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    app = _build_test_app(session_maker)

    async with session_maker() as session:
        board, task, worker = await _seed_task_update_fixture(session, token=token)

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.patch(
                f"/api/v1/agent/boards/{board.id}/tasks/{task.id}",
                headers={"Authorization": f"Bearer {token}"},
                json={"assigned_agent_id": str(worker.id)},
            )

        assert response.status_code == 200, response.text
        body = response.json()
        assert body["id"] == str(task.id)
        assert body["board_id"] == str(board.id)
        assert body["assigned_agent_id"] == str(worker.id)
        assert body["status"] == "inbox"
    finally:
        await engine.dispose()
