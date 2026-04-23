# ruff: noqa: INP001

from __future__ import annotations

from typing import Any
from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from app.core.time import utcnow
from app.models.board_memory import BoardMemory
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.organizations import Organization
from app.services.openclaw import gateway_dispatch
from app.services.openclaw.gateway_dispatch import GatewayDispatchService
from app.services.openclaw.gateway_rpc import GatewayConfig as GatewayClientConfig, OpenClawGatewayError


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


@pytest.mark.asyncio
async def test_is_board_paused_ignores_new_command_for_pause_state() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn:
        await conn.run_sync(SQLModel.metadata.create_all)

    session_maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async with session_maker() as session:
        organization = Organization(name="org")
        session.add(organization)
        await session.flush()

        board = Board(
            organization_id=organization.id,
            name="Board",
            slug="board",
        )
        session.add(board)
        await session.flush()

        now = utcnow()
        session.add(
            BoardMemory(
                board_id=board.id,
                content="/pause",
                is_chat=True,
                created_at=now - timedelta(seconds=2),
            )
        )
        session.add(
            BoardMemory(
                board_id=board.id,
                content="/new",
                is_chat=True,
                created_at=now - timedelta(seconds=1),
            )
        )
        await session.commit()

        service = GatewayDispatchService(session=session)
        assert await service._is_board_paused(board.id) is True

    await engine.dispose()


@pytest.mark.asyncio
async def test_send_agent_message_blocks_when_paused_with_session_inferred_board(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn:
        await conn.run_sync(SQLModel.metadata.create_all)

    session_maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    sent: list[str] = []

    async def _fake_ensure_session(*args: Any, **kwargs: Any) -> dict[str, Any]:
        _ = args, kwargs
        return {"ok": True}

    async def _fake_send_message(message: str, *args: Any, **kwargs: Any) -> None:
        _ = args, kwargs
        sent.append(message)

    monkeypatch.setattr(gateway_dispatch, "ensure_session", _fake_ensure_session)
    monkeypatch.setattr(gateway_dispatch, "send_message", _fake_send_message)

    async with session_maker() as session:
        organization = Organization(name="org")
        session.add(organization)
        await session.flush()

        gateway = Gateway(
            organization_id=organization.id,
            name="gw",
            url="ws://gateway.local/ws",
            workspace_root="/tmp/workspace",
        )
        session.add(gateway)
        await session.flush()

        board = Board(
            organization_id=organization.id,
            gateway_id=gateway.id,
            name="Board",
            slug="board",
        )
        session.add(board)
        await session.flush()

        session.add(
            Agent(
                board_id=board.id,
                gateway_id=gateway.id,
                name="Worker",
                status="online",
                openclaw_session_id="agent:session",
            )
        )

        now = utcnow()
        session.add(
            BoardMemory(
                board_id=board.id,
                content="/pause",
                is_chat=True,
                created_at=now,
            )
        )
        await session.commit()

        service = GatewayDispatchService(session=session)
        with pytest.raises(OpenClawGatewayError, match="paused"):
            await service.send_agent_message(
                session_key="agent:session",
                config=GatewayClientConfig(url="ws://gateway.local/ws"),
                agent_name="Worker",
                message="Please continue working",
                deliver=False,
            )

        assert sent == []

    await engine.dispose()


@pytest.mark.asyncio
async def test_send_agent_message_verifies_delivered_messages(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = GatewayDispatchService(session=object())

    async def _fake_ensure_session(*args: Any, **kwargs: Any) -> dict[str, Any]:
        _ = args, kwargs
        return {"ok": True}

    async def _fake_send_message(*args: Any, **kwargs: Any) -> dict[str, Any]:
        _ = args, kwargs
        return {"status": "started"}

    async def _fake_get_chat_history(*args: Any, **kwargs: Any) -> dict[str, Any]:
        _ = args, kwargs
        return {"messages": [{"content": [{"type": "text", "text": "Please continue working"}]}]}

    async def _fake_resolve_board(*args: Any, **kwargs: Any) -> None:
        _ = args, kwargs
        return None

    async def _fake_should_skip(*args: Any, **kwargs: Any) -> bool:
        _ = args, kwargs
        return False

    monkeypatch.setattr(gateway_dispatch, "ensure_session", _fake_ensure_session)
    monkeypatch.setattr(gateway_dispatch, "send_message", _fake_send_message)
    monkeypatch.setattr(gateway_dispatch, "get_chat_history", _fake_get_chat_history)
    monkeypatch.setattr(
        gateway_dispatch.GatewayDispatchService,
        "_resolve_board_for_pause_check",
        _fake_resolve_board,
    )
    monkeypatch.setattr(
        gateway_dispatch.GatewayDispatchService,
        "_should_skip_for_paused_board",
        _fake_should_skip,
    )

    await service.send_agent_message(
        session_key="agent:session",
        config=GatewayClientConfig(url="ws://gateway.local/ws"),
        agent_name="Worker",
        message="Please continue working",
        deliver=True,
    )


@pytest.mark.asyncio
async def test_send_agent_message_raises_when_delivered_message_missing_from_history(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = GatewayDispatchService(session=object())

    async def _fake_ensure_session(*args: Any, **kwargs: Any) -> dict[str, Any]:
        _ = args, kwargs
        return {"ok": True}

    async def _fake_send_message(*args: Any, **kwargs: Any) -> dict[str, Any]:
        _ = args, kwargs
        return {"status": "started"}

    async def _fake_get_chat_history(*args: Any, **kwargs: Any) -> dict[str, Any]:
        _ = args, kwargs
        return {"messages": [{"content": [{"type": "text", "text": "Different message"}]}]}

    async def _fake_sleep(_seconds: float) -> None:
        return None

    async def _fake_resolve_board(*args: Any, **kwargs: Any) -> None:
        _ = args, kwargs
        return None

    async def _fake_should_skip(*args: Any, **kwargs: Any) -> bool:
        _ = args, kwargs
        return False

    monkeypatch.setattr(gateway_dispatch, "ensure_session", _fake_ensure_session)
    monkeypatch.setattr(gateway_dispatch, "send_message", _fake_send_message)
    monkeypatch.setattr(gateway_dispatch, "get_chat_history", _fake_get_chat_history)
    monkeypatch.setattr(gateway_dispatch.asyncio, "sleep", _fake_sleep)
    monkeypatch.setattr(
        gateway_dispatch.GatewayDispatchService,
        "_resolve_board_for_pause_check",
        _fake_resolve_board,
    )
    monkeypatch.setattr(
        gateway_dispatch.GatewayDispatchService,
        "_should_skip_for_paused_board",
        _fake_should_skip,
    )

    with pytest.raises(OpenClawGatewayError, match="not present in recent chat history"):
        await service.send_agent_message(
            session_key="agent:session",
            config=GatewayClientConfig(url="ws://gateway.local/ws"),
            agent_name="Worker",
            message="Please continue working",
            deliver=True,
        )
