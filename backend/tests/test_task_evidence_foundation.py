from __future__ import annotations

from uuid import uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api import task_evidence as task_evidence_api
from app.api import tasks as tasks_api
from app.api.deps import ActorContext
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.organizations import Organization
from app.models.task_evidence import (
    TaskEvidenceArtifact,
    TaskEvidenceCheck,
    TaskEvidencePacket,
)
from app.models.tasks import Task
from app.schemas.task_evidence import TaskEvidencePacketCreate
from app.schemas.tasks import TaskUpdate


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
    task_status: str = "review",
    closure_mode: str | None = None,
    required_artifact_kinds: list[str] | None = None,
    required_check_kinds: list[str] | None = None,
    description: str | None = None,
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
        id=uuid4(),
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
        title="Task",
        description=description,
        status=task_status,
        assigned_agent_id=agent.id,
        closure_mode=closure_mode,
        required_artifact_kinds=required_artifact_kinds or [],
        required_check_kinds=required_check_kinds or [],
    )

    session.add(Organization(id=organization_id, name=f"org-{organization_id}"))
    session.add(gateway)
    session.add(board)
    session.add(task)
    session.add(agent)
    await session.commit()
    return board, task, agent


def _agent_actor(agent: Agent) -> ActorContext:
    return ActorContext(actor_type="agent", agent=agent)


@pytest.mark.asyncio
async def test_task_evidence_packet_can_be_created_and_read() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(session)

            created = await task_evidence_api.create_task_evidence(
                payload=TaskEvidencePacketCreate(
                    task_class="design_exploratory",
                    status="submitted",
                    summary="Summarized the design tradeoffs.",
                    implementation_delta="Added the first reviewable draft.",
                    artifacts=[
                        {
                            "kind": "spec",
                            "label": "Primary spec",
                            "workspace_agent_id": str(agent.id),
                            "workspace_agent_name": agent.name,
                            "workspace_root_key": f"agent:{agent.id}",
                            "relative_path": "deliverables/spec.md",
                            "display_path": f"{agent.name}/deliverables/spec.md",
                            "origin_kind": "original_worker_output",
                            "is_primary": True,
                        }
                    ],
                    checks=[
                        {
                            "kind": "manual_verification",
                            "label": "Peer spot-check",
                            "status": "passed",
                            "command": "read deliverables/spec.md",
                            "result_summary": "Spec reviewed and coherent.",
                        }
                    ],
                ),
                task=task,
                session=session,
                actor=_agent_actor(agent),
            )

            packets = await task_evidence_api.list_task_evidence(
                task=task,
                session=session,
                _actor=_agent_actor(agent),
            )

            assert created.status == "submitted"
            assert created.primary_artifact is not None
            assert created.primary_artifact.kind == "spec"
            assert created.primary_artifact.display_path == f"{agent.name}/deliverables/spec.md"
            assert len(packets) == 1
            assert packets[0].id == created.id
            assert packets[0].checks[0].status == "passed"
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_evidence_packet_closure_blocks_done_without_submitted_packet() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(
                session,
                closure_mode="evidence_packet",
                required_artifact_kinds=["deliverable"],
            )

            with pytest.raises(HTTPException) as exc:
                await tasks_api.update_task(
                    payload=TaskUpdate(status="done"),
                    task=task,
                    session=session,
                    actor=_agent_actor(agent),
                )

            assert exc.value.status_code == 409
            assert exc.value.detail["message"] == (
                "Task can only be marked done after a submitted evidence packet is attached."
            )
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_evidence_packet_closure_blocks_done_when_required_artifact_kind_missing() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(
                session,
                closure_mode="evidence_packet",
                required_artifact_kinds=["deliverable"],
            )

            packet = TaskEvidencePacket(
                board_id=task.board_id,
                task_id=task.id,
                created_by_agent_id=agent.id,
                status="submitted",
                submitted_at=task.created_at,
            )
            session.add(packet)
            await session.flush()
            artifact = TaskEvidenceArtifact(
                packet_id=packet.id,
                task_id=task.id,
                kind="spec",
                label="Spec draft",
                is_primary=True,
            )
            session.add(artifact)
            await session.flush()
            packet.primary_artifact_id = artifact.id
            session.add(packet)
            await session.commit()

            with pytest.raises(HTTPException) as exc:
                await tasks_api.update_task(
                    payload=TaskUpdate(status="done"),
                    task=task,
                    session=session,
                    actor=_agent_actor(agent),
                )

            assert exc.value.status_code == 409
            assert exc.value.detail["message"] == (
                "Task evidence is missing required artifact kinds: deliverable."
            )
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_passing_checks_closure_blocks_done_when_required_check_is_not_passing() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(
                session,
                closure_mode="passing_checks",
                required_artifact_kinds=["deliverable"],
                required_check_kinds=["test"],
            )

            packet = TaskEvidencePacket(
                board_id=task.board_id,
                task_id=task.id,
                created_by_agent_id=agent.id,
                status="submitted",
                submitted_at=task.created_at,
            )
            session.add(packet)
            await session.flush()
            artifact = TaskEvidenceArtifact(
                packet_id=packet.id,
                task_id=task.id,
                kind="deliverable",
                label="Patch notes",
                is_primary=True,
            )
            session.add(artifact)
            await session.flush()
            packet.primary_artifact_id = artifact.id
            session.add(
                TaskEvidenceCheck(
                    packet_id=packet.id,
                    task_id=task.id,
                    kind="test",
                    label="pytest",
                    status="failed",
                    command="pytest backend/tests",
                    result_summary="One regression still failing.",
                )
            )
            session.add(packet)
            await session.commit()

            with pytest.raises(HTTPException) as exc:
                await tasks_api.update_task(
                    payload=TaskUpdate(status="done"),
                    task=task,
                    session=session,
                    actor=_agent_actor(agent),
                )

            assert exc.value.status_code == 409
            assert exc.value.detail["message"] == (
                "Task evidence has required checks that are not passing: test."
            )
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_legacy_manual_review_tasks_still_close_without_evidence() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(
                session,
                closure_mode="manual_review",
            )

            updated = await tasks_api.update_task(
                payload=TaskUpdate(status="done"),
                task=task,
                session=session,
                actor=_agent_actor(agent),
            )

            assert updated.status == "done"
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_evidence_intent_signal_tasks_close_with_submitted_packet_and_primary_artifact() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(
                session,
                description="Deliverable file: deliverables/show-disk-space.sh",
            )

            created = await task_evidence_api.create_task_evidence(
                payload=TaskEvidencePacketCreate(
                    status="submitted",
                    summary="Verifier validated the deliverable.",
                    artifacts=[
                        {
                            "kind": "deliverable",
                            "label": "show-disk-space.sh",
                            "relative_path": "deliverables/show-disk-space.sh",
                            "display_path": "deliverables/show-disk-space.sh",
                            "origin_kind": "workspace_file",
                            "is_primary": True,
                        }
                    ],
                ),
                task=task,
                session=session,
                actor=_agent_actor(agent),
            )

            updated = await tasks_api.update_task(
                payload=TaskUpdate(status="done"),
                task=task,
                session=session,
                actor=_agent_actor(agent),
            )

            assert created.primary_artifact is not None
            assert created.primary_artifact.kind == "deliverable"
            assert updated.status == "done"
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_task_verification_rules_can_be_created_and_updated() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(session)

            rules = {
                "preflight": {
                    "skip_deliverable_by_filename": True,
                    "skip_static_only_rejection": True,
                },
                "required_patterns": ["/home/cronjev/.openclaw/workspace/"],
            }

            updated = await tasks_api.update_task(
                payload=TaskUpdate(verification_rules=rules),
                task=task,
                session=session,
                actor=_agent_actor(agent),
            )

            assert updated.verification_rules == rules
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_task_verification_rules_defaults_to_none() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            _board, task, agent = await _seed_board_task_and_agent(session)

            assert task.verification_rules is None
    finally:
        await engine.dispose()
