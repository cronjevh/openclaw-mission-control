# ruff: noqa: S101
"""Unit tests for lead-agent update behavior."""

from __future__ import annotations

from dataclasses import dataclass
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException, status

import app.services.openclaw.provisioning_db as agent_service
from app.schemas.agents import AgentUpdate
from app.services.openclaw.gateway_rpc import GatewayConfig as GatewayClientConfig


@dataclass
class _FakeSession:
    committed: int = 0
    refreshed: list[object] | None = None

    def add(self, _value: object) -> None:
        return None

    async def commit(self) -> None:
        self.committed += 1

    async def refresh(self, value: object) -> None:
        if self.refreshed is None:
            self.refreshed = []
        self.refreshed.append(value)


@dataclass
class _AgentStub:
    id: UUID
    name: str
    gateway_id: UUID
    board_id: UUID | None = None
    is_board_lead: bool = False
    identity_profile: dict[str, str] | None = None


@dataclass
class _BoardStub:
    id: UUID
    gateway_id: UUID


@dataclass
class _GatewayStub:
    id: UUID
    url: str
    token: str | None
    workspace_root: str


@pytest.mark.asyncio
async def test_update_agent_as_lead_updates_board_worker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    session = _FakeSession()
    service = agent_service.AgentLifecycleService(session)  # type: ignore[arg-type]

    gateway_id = uuid4()
    board = _BoardStub(id=uuid4(), gateway_id=gateway_id)
    lead = _AgentStub(
        id=uuid4(),
        name="Atlas",
        gateway_id=gateway_id,
        board_id=board.id,
        is_board_lead=True,
    )
    target = _AgentStub(
        id=uuid4(),
        name="Athena",
        gateway_id=gateway_id,
        board_id=board.id,
        identity_profile={"role": "Researcher"},
    )
    gateway = _GatewayStub(
        id=gateway_id,
        url="ws://gateway.example/ws",
        token=None,
        workspace_root="/tmp/openclaw",
    )

    async def _fake_first_agent(_session: object) -> _AgentStub:
        return target

    monkeypatch.setattr(
        agent_service.Agent,
        "objects",
        SimpleNamespace(by_id=lambda _id: SimpleNamespace(first=_fake_first_agent)),
    )

    async def _fake_require_board(_board_id: object, **_kwargs: object) -> _BoardStub:
        return board

    async def _fake_require_gateway(
        _board: object,
    ) -> tuple[_GatewayStub, GatewayClientConfig]:
        return gateway, GatewayClientConfig(url=gateway.url, token=None)

    ensure_unique_calls: list[dict[str, object]] = []

    async def _fake_ensure_unique_agent_name(**kwargs: object) -> None:
        ensure_unique_calls.append(kwargs)

    async def _fake_apply_agent_update_mutations(
        *,
        agent: _AgentStub,
        updates: dict[str, object],
        make_main: bool | None,
    ) -> tuple[None, None]:
        assert make_main is None
        if "name" in updates:
            agent.name = str(updates["name"])
        if "identity_profile" in updates:
            agent.identity_profile = updates["identity_profile"]  # type: ignore[assignment]
        return None, None

    async def _fake_resolve_agent_update_target(**_kwargs: object) -> SimpleNamespace:
        return SimpleNamespace(is_main_agent=False, board=board, gateway=gateway)

    provision_requests: list[object] = []

    def _fake_mark_agent_update_pending(_agent: object) -> str:
        return "raw-token"

    async def _fake_provision_updated_agent(*, request: object, **_kwargs: object) -> None:
        provision_requests.append(request)

    monkeypatch.setattr(service, "require_board", _fake_require_board)
    monkeypatch.setattr(service, "require_gateway", _fake_require_gateway)
    monkeypatch.setattr(service, "ensure_unique_agent_name", _fake_ensure_unique_agent_name)
    monkeypatch.setattr(
        service,
        "apply_agent_update_mutations",
        _fake_apply_agent_update_mutations,
    )
    monkeypatch.setattr(
        service,
        "resolve_agent_update_target",
        _fake_resolve_agent_update_target,
    )
    monkeypatch.setattr(service, "mark_agent_update_pending", _fake_mark_agent_update_pending)
    monkeypatch.setattr(service, "provision_updated_agent", _fake_provision_updated_agent)
    monkeypatch.setattr(service, "with_computed_status", lambda agent: agent)
    monkeypatch.setattr(
        service,
        "to_agent_read",
        lambda agent: {
            "id": str(agent.id),
            "name": agent.name,
            "identity_profile": agent.identity_profile,
        },
    )

    result = await service.update_agent_as_lead(
        agent_id=str(target.id),
        payload=AgentUpdate(
            name="Hermes",
            identity_profile={"role": "Operations Specialist"},
        ),
        actor_agent=lead,  # type: ignore[arg-type]
    )

    assert result["name"] == "Hermes"
    assert result["identity_profile"] == {"role": "Operations Specialist"}
    assert ensure_unique_calls and ensure_unique_calls[0]["exclude_agent_id"] == target.id
    assert ensure_unique_calls[0]["requested_name"] == "Hermes"
    assert provision_requests
    assert session.committed == 1


@pytest.mark.asyncio
async def test_update_agent_as_lead_rejects_gateway_main(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    session = _FakeSession()
    service = agent_service.AgentLifecycleService(session)  # type: ignore[arg-type]

    gateway_id = uuid4()
    board_id = uuid4()
    lead = _AgentStub(
        id=uuid4(),
        name="Atlas",
        gateway_id=gateway_id,
        board_id=board_id,
        is_board_lead=True,
    )
    target = _AgentStub(
        id=uuid4(),
        name="Gateway Main",
        gateway_id=gateway_id,
        board_id=None,
    )

    async def _fake_first_agent(_session: object) -> _AgentStub:
        return target

    monkeypatch.setattr(
        agent_service.Agent,
        "objects",
        SimpleNamespace(by_id=lambda _id: SimpleNamespace(first=_fake_first_agent)),
    )

    with pytest.raises(HTTPException) as exc_info:
        await service.update_agent_as_lead(
            agent_id=str(target.id),
            payload=AgentUpdate(name="Renamed"),
            actor_agent=lead,  # type: ignore[arg-type]
        )

    assert exc_info.value.status_code == status.HTTP_403_FORBIDDEN
    assert "gateway main" in str(exc_info.value.detail).lower()


@pytest.mark.asyncio
async def test_update_agent_as_lead_rejects_cross_board_move(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    session = _FakeSession()
    service = agent_service.AgentLifecycleService(session)  # type: ignore[arg-type]

    gateway_id = uuid4()
    board = _BoardStub(id=uuid4(), gateway_id=gateway_id)
    lead = _AgentStub(
        id=uuid4(),
        name="Atlas",
        gateway_id=gateway_id,
        board_id=board.id,
        is_board_lead=True,
    )
    target = _AgentStub(
        id=uuid4(),
        name="Athena",
        gateway_id=gateway_id,
        board_id=board.id,
    )

    async def _fake_first_agent(_session: object) -> _AgentStub:
        return target

    monkeypatch.setattr(
        agent_service.Agent,
        "objects",
        SimpleNamespace(by_id=lambda _id: SimpleNamespace(first=_fake_first_agent)),
    )

    async def _fake_require_board(_board_id: object, **_kwargs: object) -> _BoardStub:
        return board

    monkeypatch.setattr(service, "require_board", _fake_require_board)

    with pytest.raises(HTTPException) as exc_info:
        await service.update_agent_as_lead(
            agent_id=str(target.id),
            payload=AgentUpdate(board_id=uuid4()),
            actor_agent=lead,  # type: ignore[arg-type]
        )

    assert exc_info.value.status_code == status.HTTP_403_FORBIDDEN
    assert "own board" in str(exc_info.value.detail).lower()
