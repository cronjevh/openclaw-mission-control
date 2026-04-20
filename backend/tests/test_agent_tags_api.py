from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException

from app.api import agent as agent_api
from app.core.agent_auth import AgentAuthContext
from app.models.agents import Agent
from app.models.boards import Board
from app.models.tags import Tag


@dataclass
class _FakeExecResult:
    value: object

    def all(self) -> object:
        return self.value

    def first(self) -> object:
        if isinstance(self.value, list):
            return self.value[0] if self.value else None
        return self.value

    def one(self) -> object:
        return self.value


@dataclass
class _FakeSession:
    results: list[object]
    calls: int = 0

    async def exec(self, _query: object) -> _FakeExecResult:
        index = min(self.calls, len(self.results) - 1)
        self.calls += 1
        return _FakeExecResult(self.results[index])


def _board() -> Board:
    return Board(
        id=uuid4(),
        organization_id=uuid4(),
        name="Delivery",
        slug="delivery",
    )


def _agent_ctx(*, board_id: UUID | None) -> AgentAuthContext:
    return AgentAuthContext(
        actor_type="agent",
        agent=Agent(
            id=uuid4(),
            board_id=board_id,
            gateway_id=uuid4(),
            name="Lead",
            is_board_lead=True,
        ),
    )


@pytest.mark.asyncio
async def test_list_tags_returns_tag_refs() -> None:
    board = _board()
    session = _FakeSession(
        results=[[
            Tag(
                id=uuid4(),
                organization_id=board.organization_id,
                name="Backend",
                slug="backend",
                color="0f172a",
            ),
            Tag(
                id=uuid4(),
                organization_id=board.organization_id,
                name="Urgent",
                slug="urgent",
                color="dc2626",
            ),
        ]],
    )

    response = await agent_api.list_tags(
        board=board,
        session=session,  # type: ignore[arg-type]
        agent_ctx=_agent_ctx(board_id=board.id),
    )

    assert [tag.slug for tag in response] == ["backend", "urgent"]
    assert response[0].name == "Backend"
    assert response[1].color == "dc2626"


@pytest.mark.asyncio
async def test_list_tags_rejects_cross_board_agent() -> None:
    board = _board()
    session = _FakeSession(results=[[]])

    with pytest.raises(HTTPException) as exc:
        await agent_api.list_tags(
            board=board,
            session=session,  # type: ignore[arg-type]
            agent_ctx=_agent_ctx(board_id=uuid4()),
        )

    assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_get_tag_returns_tag_read_with_description_and_count() -> None:
    board = _board()
    tag = Tag(
        id=uuid4(),
        organization_id=board.organization_id,
        name="Mission Control Mechanics",
        slug="project-mission-control-mechanics",
        color="2563eb",
        description="## Objective`nMake project state visible.",
    )
    session = _FakeSession(results=[tag, 3])

    response = await agent_api.get_tag(
        tag_id=tag.id,
        board=board,
        session=session,  # type: ignore[arg-type]
        agent_ctx=_agent_ctx(board_id=board.id),
    )

    assert response.id == tag.id
    assert response.description == tag.description
    assert response.task_count == 3


@pytest.mark.asyncio
async def test_get_tag_rejects_cross_board_agent() -> None:
    board = _board()
    session = _FakeSession(results=[None])

    with pytest.raises(HTTPException) as exc:
        await agent_api.get_tag(
            tag_id=uuid4(),
            board=board,
            session=session,  # type: ignore[arg-type]
            agent_ctx=_agent_ctx(board_id=uuid4()),
        )

    assert exc.value.status_code == 403
