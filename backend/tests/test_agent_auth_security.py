# ruff: noqa: INP001, SLF001
"""Regression tests for agent-auth security hardening."""

from __future__ import annotations

from types import SimpleNamespace
from uuid import UUID

import pytest
from fastapi import HTTPException

from app.api import deps
from app.core import agent_auth
from app.core.agent_tokens import generate_stable_agent_token, hash_agent_token
from app.core.auth import AuthContext


class _RecordingLimiter:
    def __init__(self) -> None:
        self.keys: list[str] = []

    async def is_allowed(self, key: str) -> bool:
        self.keys.append(key)
        return True


async def _noop_touch(*_: object, **__: object) -> None:
    return None


@pytest.mark.asyncio
async def test_optional_agent_auth_rate_limits_bearer_agent_token(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    limiter = _RecordingLimiter()
    agent = SimpleNamespace(id="agent-1")
    request = SimpleNamespace(
        headers={"Authorization": "Bearer agent-secret"},
        client=SimpleNamespace(host="203.0.113.10"),
        url=SimpleNamespace(path="/api/v1/tasks/task-1"),
        method="POST",
    )

    async def _fake_find(_session: object, token: str, **_: object) -> object:
        assert token == "agent-secret"
        return agent

    monkeypatch.setattr(agent_auth, "agent_auth_limiter", limiter)
    monkeypatch.setattr(agent_auth, "_find_agent_for_token", _fake_find)
    monkeypatch.setattr(agent_auth, "_touch_agent_presence", _noop_touch)

    ctx = await agent_auth.get_agent_auth_context_optional(
        request=request,  # type: ignore[arg-type]
        agent_token=None,
        authorization="Bearer agent-secret",
        session=SimpleNamespace(),  # type: ignore[arg-type]
    )

    assert ctx is not None
    assert ctx.agent is agent
    assert limiter.keys == ["203.0.113.10"]


@pytest.mark.asyncio
async def test_require_user_or_agent_skips_agent_auth_when_user_auth_succeeds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = SimpleNamespace(
        headers={"Authorization": "Bearer user-token"},
        client=SimpleNamespace(host="203.0.113.20"),
    )

    async def _fake_user_auth(**_: object) -> AuthContext:
        return AuthContext(actor_type="user", user=SimpleNamespace(id="user-1"))

    async def _boom_agent_auth(**_: object) -> object:
        raise AssertionError("agent auth should not run when user auth already succeeded")

    monkeypatch.setattr(deps, "get_auth_context_optional", _fake_user_auth)
    monkeypatch.setattr(deps, "get_agent_auth_context_optional", _boom_agent_auth)

    actor = await deps.require_user_or_agent(
        request=request,  # type: ignore[arg-type]
        session=SimpleNamespace(),  # type: ignore[arg-type]
    )

    assert actor.actor_type == "user"
    assert actor.user is not None


@pytest.mark.asyncio
async def test_required_agent_auth_invalid_token_logs_short_prefix_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    limiter = _RecordingLimiter()
    logged: list[tuple[str, tuple[object, ...]]] = []
    request = SimpleNamespace(
        headers={"X-Agent-Token": "invalid-agent-token"},
        client=SimpleNamespace(host="203.0.113.30"),
        url=SimpleNamespace(path="/api/v1/agent/boards"),
        method="POST",
    )

    async def _fake_find(_session: object, _token: str, **_kw: object) -> None:
        return None

    def _fake_warning(message: str, *args: object, **_: object) -> None:
        logged.append((message, args))

    monkeypatch.setattr(agent_auth, "agent_auth_limiter", limiter)
    monkeypatch.setattr(agent_auth, "_find_agent_for_token", _fake_find)
    monkeypatch.setattr(agent_auth.logger, "warning", _fake_warning)

    with pytest.raises(HTTPException) as exc_info:
        await agent_auth.get_agent_auth_context(
            request=request,  # type: ignore[arg-type]
            agent_token="invalid-agent-token",
            authorization=None,
            session=SimpleNamespace(),  # type: ignore[arg-type]
        )

    assert exc_info.value.status_code == 401
    assert logged == [
        (
            "agent auth invalid token path=%s token_prefix=%s",
            ("/api/v1/agent/boards", "invali"),
        )
    ]


@pytest.mark.asyncio
async def test_optional_agent_auth_invalid_token_logs_short_prefix_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    limiter = _RecordingLimiter()
    logged: list[tuple[str, tuple[object, ...]]] = []
    request = SimpleNamespace(
        headers={"Authorization": "Bearer invalid-agent-token"},
        client=SimpleNamespace(host="203.0.113.40"),
        url=SimpleNamespace(path="/api/v1/tasks/task-2"),
        method="POST",
    )

    async def _fake_find(_session: object, _token: str, **_kw: object) -> None:
        return None

    def _fake_warning(message: str, *args: object, **_: object) -> None:
        logged.append((message, args))

    monkeypatch.setattr(agent_auth, "agent_auth_limiter", limiter)
    monkeypatch.setattr(agent_auth, "_find_agent_for_token", _fake_find)
    monkeypatch.setattr(agent_auth.logger, "warning", _fake_warning)

    ctx = await agent_auth.get_agent_auth_context_optional(
        request=request,  # type: ignore[arg-type]
        agent_token=None,
        authorization="Bearer invalid-agent-token",
        session=SimpleNamespace(),  # type: ignore[arg-type]
    )

    assert ctx is None
    assert logged == [
        (
            "agent auth optional invalid token path=%s token_prefix=%s",
            ("/api/v1/tasks/task-2", "invali"),
        )
    ]


@pytest.mark.asyncio
async def test_find_agent_for_token_accepts_stable_token_even_when_hash_is_stale() -> None:
    agent = SimpleNamespace(
        id="2a95bc8b-5cf2-42fb-bab8-7eb0db83ed6f",
        agent_token_hash=hash_agent_token("old-random-token"),
    )

    class _FakeSession:
        async def exec(self, _stmt: object) -> list[object]:
            return [agent]

    resolved = await agent_auth._find_agent_for_token(
        _FakeSession(),  # type: ignore[arg-type]
        generate_stable_agent_token(agent.id),
    )

    assert resolved is agent


@pytest.mark.asyncio
async def test_find_agent_for_token_disambiguates_legacy_hash_by_board_hint() -> None:
    legacy_token = "shared-legacy-token"
    board_a = UUID("dd95369d-1497-41f2-8aeb-e06b51b63162")
    board_b = UUID("27ea8f27-f98d-4cd8-a37d-f42c14b4a5bc")
    agent_a = SimpleNamespace(
        id="9e590c5d-9745-427f-b5c8-f0ea85f23f8c",
        board_id=board_a,
        status="online",
        agent_token_hash=hash_agent_token(legacy_token),
    )
    agent_b = SimpleNamespace(
        id="c9f73bcf-1d11-4c83-8e45-a6b9ce032b10",
        board_id=board_b,
        status="online",
        agent_token_hash=hash_agent_token(legacy_token),
    )

    class _FakeSession:
        async def exec(self, _stmt: object) -> list[object]:
            return [agent_a, agent_b]

    resolved = await agent_auth._find_agent_for_token(
        _FakeSession(),  # type: ignore[arg-type]
        legacy_token,
        board_id_hint=board_b,
    )

    assert resolved is agent_b
