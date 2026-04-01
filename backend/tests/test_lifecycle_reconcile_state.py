# ruff: noqa: INP001
"""Lifecycle reconcile state helpers."""

from __future__ import annotations

from datetime import timedelta
from uuid import uuid4

from app.core.time import utcnow
from app.models.agents import Agent
from app.services.openclaw.constants import (
    CHECKIN_DEADLINE_AFTER_WAKE,
    MAX_WAKE_ATTEMPTS_WITHOUT_CHECKIN,
)
from app.services.openclaw.lifecycle_reconcile import (
    _extract_file_content,
    _has_checked_in_since_wake,
    _parse_auth_token_from_tools,
)


def _agent(*, last_seen_offset_s: int | None, last_wake_offset_s: int | None) -> Agent:
    now = utcnow()
    return Agent(
        name="reconcile-test",
        gateway_id=uuid4(),
        last_seen_at=(
            (now + timedelta(seconds=last_seen_offset_s))
            if last_seen_offset_s is not None
            else None
        ),
        last_wake_sent_at=(
            (now + timedelta(seconds=last_wake_offset_s))
            if last_wake_offset_s is not None
            else None
        ),
    )


def test_checked_in_since_wake_when_last_seen_after_wake() -> None:
    agent = _agent(last_seen_offset_s=5, last_wake_offset_s=0)
    assert _has_checked_in_since_wake(agent) is True


def test_not_checked_in_since_wake_when_last_seen_before_wake() -> None:
    agent = _agent(last_seen_offset_s=-5, last_wake_offset_s=0)
    assert _has_checked_in_since_wake(agent) is False


def test_not_checked_in_since_wake_when_missing_last_seen() -> None:
    agent = _agent(last_seen_offset_s=None, last_wake_offset_s=0)
    assert _has_checked_in_since_wake(agent) is False


def test_lifecycle_convergence_policy_constants() -> None:
    assert CHECKIN_DEADLINE_AFTER_WAKE == timedelta(seconds=30)
    assert MAX_WAKE_ATTEMPTS_WITHOUT_CHECKIN == 3


def test_parse_auth_token_from_tools_reads_plain_assignment() -> None:
    content = "BASE_URL=http://localhost:8002\nAUTH_TOKEN=abc123\nAGENT_NAME=Atlas\n"
    assert _parse_auth_token_from_tools(content) == "abc123"


def test_parse_auth_token_from_tools_ignores_bullet_lines() -> None:
    content = "- `AUTH_TOKEN=abc123`\n"
    assert _parse_auth_token_from_tools(content) is None


def test_extract_file_content_supports_nested_payload_shapes() -> None:
    assert _extract_file_content("raw") == "raw"
    assert _extract_file_content({"content": "top"}) == "top"
    assert _extract_file_content({"file": {"content": "nested"}}) == "nested"
    assert _extract_file_content({"file": {"content": 123}}) is None
