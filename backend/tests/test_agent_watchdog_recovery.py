from __future__ import annotations

from datetime import timedelta
from uuid import uuid4

from app.core.time import utcnow
from app.models.agents import Agent
from app.services.openclaw.agent_watchdog import (
    _extract_file_content,
    _needs_auto_recover,
    _parse_auth_token_from_tools,
)


def _agent(*, status: str = "online", last_seen_delta_s: int | None = None, wake_delta_s: int | None = None) -> Agent:
    now = utcnow()
    last_seen = None if last_seen_delta_s is None else now - timedelta(seconds=last_seen_delta_s)
    last_wake = None if wake_delta_s is None else now - timedelta(seconds=wake_delta_s)
    return Agent(
        id=uuid4(),
        gateway_id=uuid4(),
        name="Atlas",
        status=status,
        last_seen_at=last_seen,
        last_wake_sent_at=last_wake,
    )


def test_parse_auth_token_from_tools_reads_assignment() -> None:
    content = "BASE_URL=http://localhost:8002\nAUTH_TOKEN=abc123\n"
    assert _parse_auth_token_from_tools(content) == "abc123"


def test_extract_file_content_supports_nested_shapes() -> None:
    assert _extract_file_content("raw") == "raw"
    assert _extract_file_content({"content": "top"}) == "top"
    assert _extract_file_content({"file": {"content": "nested"}}) == "nested"
    assert _extract_file_content({"file": {"content": 1}}) is None


def test_needs_auto_recover_for_offline_agent() -> None:
    now = utcnow()
    agent = _agent(status="offline", last_seen_delta_s=5)
    assert _needs_auto_recover(agent, now=now) is True


def test_needs_auto_recover_false_during_wake_cooldown() -> None:
    now = utcnow()
    agent = _agent(status="offline", last_seen_delta_s=1000, wake_delta_s=10)
    assert _needs_auto_recover(agent, now=now) is False
