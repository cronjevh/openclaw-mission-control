from __future__ import annotations

from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api import agent as agent_api
from app.core.agent_auth import AgentAuthContext
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.organizations import Organization
from app.models.tasks import Task
from app.schemas.task_evidence import TaskEvidencePacketCreate


async def _make_engine() -> AsyncEngine:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn, conn.begin():
        await conn.run_sync(SQLModel.metadata.create_all)
    return engine


async def _make_session(engine: AsyncEngine) -> AsyncSession:
    return AsyncSession(engine, expire_on_commit=False)


async def _seed_board_task_and_agent(
    session: AsyncSession,
    *,
    board_id: UUID | None = None,
) -> tuple[Board, Task, Agent]:
    organization_id = uuid4()
    gateway = Gateway(
        id=uuid4(),
        organization_id=organization_id,
        name="gateway",
        url="https://gateway.local",
        workspace_root="/tmp/workspace",
    )
    board = Board(
        id=board_id or uuid4(),
        organization_id=organization_id,
        gateway_id=gateway.id,
        name="board",
        slug=f"board-{uuid4()}",
        require_approval_for_done=False,
    )
    agent = Agent(
        id=uuid4(),
        board_id=board.id,
        gateway_id=gateway.id,
        name="worker",
        status="online",
    )
    task = Task(
        id=uuid4(),
        board_id=board.id,
        title="Evidence task",
        status="review",
        assigned_agent_id=agent.id,
    )

    session.add(Organization(id=organization_id, name=f"org-{organization_id}"))
    session.add(gateway)
    session.add(board)
    session.add(task)
    session.add(agent)
    await session.commit()
    return board, task, agent


def _agent_ctx(agent: Agent) -> AgentAuthContext:
    return AgentAuthContext(actor_type="agent", agent=agent)


@pytest.mark.asyncio
async def test_agent_can_create_and_list_task_evidence_packets() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(session)

            created = await agent_api.create_task_evidence_packet_for_agent(
                payload=TaskEvidencePacketCreate(
                    task_class="ops_integration",
                    status="submitted",
                    summary="Validated the task through the agent-scoped evidence route.",
                    artifacts=[
                        {
                            "kind": "deliverable",
                            "label": "Generated report",
                            "workspace_agent_id": str(agent.id),
                            "workspace_agent_name": agent.name,
                            "workspace_root_key": f"agent:{agent.id}",
                            "relative_path": "deliverables/report.md",
                            "display_path": f"{agent.name}/deliverables/report.md",
                            "origin_kind": "original_worker_output",
                            "is_primary": True,
                        }
                    ],
                    checks=[
                        {
                            "kind": "manual_verification",
                            "label": "Lead spot check",
                            "status": "passed",
                            "result_summary": "Evidence packet is present and coherent.",
                        }
                    ],
                ),
                task=task,
                session=session,
                agent_ctx=_agent_ctx(agent),
            )

            packets = await agent_api.list_task_evidence_packets_for_agent(
                task=task,
                session=session,
                agent_ctx=_agent_ctx(agent),
            )

            assert created.task_id == task.id
            assert created.status == "submitted"
            assert created.primary_artifact is not None
            assert created.primary_artifact.kind == "deliverable"
            assert len(packets) == 1
            assert packets[0].id == created.id
            assert packets[0].checks[0].status == "passed"
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_agent_task_evidence_route_rejects_other_board_agent() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, _agent = await _seed_board_task_and_agent(session)
            _other_board, _other_task, other_agent = await _seed_board_task_and_agent(session)

            with pytest.raises(HTTPException) as exc:
                await agent_api.list_task_evidence_packets_for_agent(
                    task=task,
                    session=session,
                    agent_ctx=_agent_ctx(other_agent),
                )

            assert exc.value.status_code == 403
    finally:
        await engine.dispose()
