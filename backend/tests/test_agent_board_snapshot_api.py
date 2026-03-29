from __future__ import annotations

from uuid import uuid4

import pytest

from app.api import agent as agent_api
from app.core.agent_auth import AgentAuthContext
from app.models.agents import Agent
from app.models.boards import Board
from app.schemas.view_models import BoardSnapshot


def _agent_ctx(*, board_id: object) -> AgentAuthContext:
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
async def test_get_board_snapshot_uses_snapshot_builder(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    board = Board(
        id=uuid4(),
        organization_id=uuid4(),
        gateway_id=uuid4(),
        name="Board",
        slug="board",
    )
    session = object()
    expected = BoardSnapshot(
        board=agent_api.BoardRead.model_validate(board, from_attributes=True),
        tasks=[],
        agents=[],
        approvals=[],
        chat_messages=[],
        pending_approvals_count=0,
    )
    called: dict[str, object] = {}

    async def _fake_build_board_snapshot(_session: object, _board: Board) -> BoardSnapshot:
        called["session"] = _session
        called["board_id"] = _board.id
        return expected

    monkeypatch.setattr(agent_api, "build_board_snapshot", _fake_build_board_snapshot)

    response = await agent_api.get_board_snapshot(
        board=board,
        session=session,  # type: ignore[arg-type]
        agent_ctx=_agent_ctx(board_id=board.id),
    )

    assert response == expected
    assert called["session"] is session
    assert called["board_id"] == board.id
