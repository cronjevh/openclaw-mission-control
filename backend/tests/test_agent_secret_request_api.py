from __future__ import annotations

from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException

from app.api import agent as agent_api
from app.core.agent_auth import AgentAuthContext
from app.models.agents import Agent
from app.models.boards import Board
from app.schemas.gateway_coordination import (
    GatewayMainSecretRequest,
    GatewayMainSecretRequestResponse,
)


def _agent_ctx(*, board_id: UUID, is_board_lead: bool) -> AgentAuthContext:
    return AgentAuthContext(
        actor_type="agent",
        agent=Agent(
            id=uuid4(),
            board_id=board_id,
            gateway_id=uuid4(),
            name="Lead",
            is_board_lead=is_board_lead,
        ),
    )


def _board(board_id: UUID) -> Board:
    return Board(
        id=board_id,
        organization_id=uuid4(),
        name="Platform",
        slug="platform",
        gateway_id=uuid4(),
    )


@pytest.mark.asyncio
async def test_secret_request_rejects_non_lead_agent() -> None:
    board_id = uuid4()

    with pytest.raises(HTTPException) as exc:
        await agent_api.request_secret_via_gateway_main(
            payload=GatewayMainSecretRequest(
                secret_key="github_token",
                content="Need secret for release job.",
            ),
            board=_board(board_id),
            session=object(),  # type: ignore[arg-type]
            agent_ctx=_agent_ctx(board_id=board_id, is_board_lead=False),
        )

    assert exc.value.status_code == 403
    assert exc.value.detail == "Only board leads can perform this action"


@pytest.mark.asyncio
async def test_secret_request_calls_coordination_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    board_id = uuid4()
    board = _board(board_id)
    lead_ctx = _agent_ctx(board_id=board_id, is_board_lead=True)
    called: dict[str, object] = {}

    async def _fake_request_secret_via_gateway_main(self, **kwargs: object) -> object:
        _ = self
        called.update(kwargs)
        return GatewayMainSecretRequestResponse(
            board_id=board_id,
            secret_key="GITHUB_TOKEN",
            target_agent_id=None,
            target_agent_name=None,
        )

    monkeypatch.setattr(
        agent_api.GatewayCoordinationService,
        "request_secret_via_gateway_main",
        _fake_request_secret_via_gateway_main,
    )

    response = await agent_api.request_secret_via_gateway_main(
        payload=GatewayMainSecretRequest(
            secret_key="github_token",
            content="Need secret for release job.",
        ),
        board=board,
        session=object(),  # type: ignore[arg-type]
        agent_ctx=lead_ctx,
    )

    assert response.ok is True
    assert response.secret_key == "GITHUB_TOKEN"
    assert called["board"] is board
    assert called["payload"].secret_key == "github_token"
    assert called["actor_agent"] is lead_ctx.agent
