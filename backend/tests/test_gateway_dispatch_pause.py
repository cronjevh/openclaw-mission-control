# ruff: noqa: INP001

from __future__ import annotations

from typing import Any
from uuid import uuid4

import pytest

from app.models.boards import Board
from app.services.openclaw import gateway_dispatch
from app.services.openclaw.gateway_dispatch import GatewayDispatchService
from app.services.openclaw.gateway_rpc import GatewayConfig as GatewayClientConfig


@pytest.mark.asyncio
async def test_try_send_skips_non_control_message_when_board_paused(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = GatewayDispatchService(session=object())
    board = Board(organization_id=uuid4(), name="Board", slug="board")

    async def _fake_is_board_paused(self: GatewayDispatchService, _board_id: object) -> bool:
        _ = self
        return True

    sent: list[dict[str, Any]] = []

    async def _fake_send_agent_message(
        self: GatewayDispatchService,
        **kwargs: Any,
    ) -> None:
        _ = self
        sent.append(kwargs)

    monkeypatch.setattr(
        gateway_dispatch.GatewayDispatchService,
        "_is_board_paused",
        _fake_is_board_paused,
    )
    monkeypatch.setattr(
        gateway_dispatch.GatewayDispatchService,
        "send_agent_message",
        _fake_send_agent_message,
    )

    error = await service.try_send_agent_message(
        session_key="agent:session",
        config=GatewayClientConfig(url="ws://gateway.local/ws"),
        agent_name="Worker",
        message="NEW TASK ADDED",
        board=board,
    )

    assert error is not None
    assert "paused" in str(error).lower()
    assert sent == []


@pytest.mark.asyncio
async def test_try_send_allows_resume_message_when_board_paused(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = GatewayDispatchService(session=object())
    board = Board(organization_id=uuid4(), name="Board", slug="board")

    async def _fake_is_board_paused(self: GatewayDispatchService, _board_id: object) -> bool:
        _ = self
        return True

    sent: list[dict[str, Any]] = []

    async def _fake_send_agent_message(
        self: GatewayDispatchService,
        **kwargs: Any,
    ) -> None:
        _ = self
        sent.append(kwargs)

    monkeypatch.setattr(
        gateway_dispatch.GatewayDispatchService,
        "_is_board_paused",
        _fake_is_board_paused,
    )
    monkeypatch.setattr(
        gateway_dispatch.GatewayDispatchService,
        "send_agent_message",
        _fake_send_agent_message,
    )

    error = await service.try_send_agent_message(
        session_key="agent:session",
        config=GatewayClientConfig(url="ws://gateway.local/ws"),
        agent_name="Worker",
        message="/resume",
        board=board,
    )

    assert error is None
    assert len(sent) == 1
