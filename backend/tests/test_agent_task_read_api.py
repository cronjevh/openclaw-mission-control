from __future__ import annotations

from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException

from app.api import agent as agent_api
from app.core.agent_auth import AgentAuthContext
from app.models.agents import Agent
from app.models.tasks import Task
from app.schemas.tasks import TaskRead


def _agent_ctx(*, board_id: UUID) -> AgentAuthContext:
    return AgentAuthContext(
        actor_type="agent",
        agent=Agent(
            id=uuid4(),
            board_id=board_id,
            gateway_id=uuid4(),
            name="Worker",
            is_board_lead=False,
        ),
    )


@pytest.mark.asyncio
async def test_get_task_rejects_agent_from_other_board() -> None:
    task = Task(
        id=uuid4(),
        board_id=uuid4(),
        title="Scoped task",
    )

    with pytest.raises(HTTPException) as exc:
        await agent_api.get_task(
            task=task,
            session=object(),  # type: ignore[arg-type]
            agent_ctx=_agent_ctx(board_id=uuid4()),
            include_comments=True,
        )

    assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_get_task_returns_task_read_and_accepts_include_comments(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    board_id = uuid4()
    task = Task(
        id=uuid4(),
        board_id=board_id,
        title="Scoped task",
        status="in_progress",
    )
    session = object()
    expected = TaskRead(
        id=task.id,
        board_id=board_id,
        board_group_id=None,
        created_by_user_id=None,
        creator_name=None,
        assignee=None,
        title=task.title,
        description=None,
        status="in_progress",
        priority="medium",
        due_at=None,
        assigned_agent_id=None,
        depends_on_task_ids=[],
        tag_ids=[],
        tags=[],
        in_progress_at=None,
        created_at=task.created_at,
        updated_at=task.updated_at,
        blocked_by_task_ids=[],
        is_blocked=False,
        custom_field_values={},
    )
    called: dict[str, object] = {}

    async def _fake_task_read_response(
        _session: object,
        *,
        task: Task,
        board_id: UUID,
    ) -> TaskRead:
        called["session"] = _session
        called["task_id"] = task.id
        called["board_id"] = board_id
        return expected

    monkeypatch.setattr(agent_api.tasks_api, "_task_read_response", _fake_task_read_response)

    response = await agent_api.get_task(
        task=task,
        session=session,  # type: ignore[arg-type]
        agent_ctx=_agent_ctx(board_id=board_id),
        include_comments=True,
    )

    assert response == expected
    assert called["session"] is session
    assert called["task_id"] == task.id
    assert called["board_id"] == board_id
