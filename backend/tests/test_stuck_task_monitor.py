"""Tests for the stuck-task monitoring routine."""

from __future__ import annotations

import json
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Add the scripts directory to the path so we can import the monitor
SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from monitor_stuck_tasks import (
    DedupState,
    MissionControlAPI,
    MonitorConfig,
    StuckResult,
    build_investigation_description,
    detect_stuck_tasks,
    format_duration_hours,
    load_config,
    load_state,
    prune_stale_state,
    resolve_auth_headers,
    save_state,
)


# ── Helpers ──────────────────────────────────────────────────────────


def _make_task(
    task_id: str = "t1",
    status: str = "in_progress",
    title: str = "Test Task",
    updated_hours_ago: float = 0,
    created_hours_ago: float = 48,
    in_progress_hours_ago: float | None = None,
    assigned_agent_id: str | None = "agent-1",
    assignee: str = "Worker",
    depends_on: list[str] | None = None,
    tags: list[dict] | None = None,
) -> dict:
    now = datetime.now(UTC)
    return {
        "id": task_id,
        "title": title,
        "status": status,
        "updated_at": (now - timedelta(hours=updated_hours_ago)).isoformat(),
        "created_at": (now - timedelta(hours=created_hours_ago)).isoformat(),
        "in_progress_at": (
            (now - timedelta(hours=in_progress_hours_ago)).isoformat()
            if in_progress_hours_ago is not None
            else None
        ),
        "assigned_agent_id": assigned_agent_id,
        "assignee": assignee,
        "depends_on_task_ids": depends_on or [],
        "tags": tags or [],
        "custom_field_values": {},
    }


def _make_config(**overrides) -> MonitorConfig:
    config = MonitorConfig()
    for k, v in overrides.items():
        setattr(config, k, v)
    return config


def _mock_api(comments: list[dict] | None = None) -> MissionControlAPI:
    api = MagicMock(spec=MissionControlAPI)
    api.list_comments.return_value = comments or []
    return api


# ── Stuck detection tests ────────────────────────────────────────────


class TestDetectStuckTasks:
    def test_in_progress_stuck_when_over_threshold(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [_make_task(status="in_progress", updated_hours_ago=25)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 1
        assert results[0].status == "in_progress"
        assert "25" in results[0].reason

    def test_in_progress_not_stuck_when_under_threshold(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [_make_task(status="in_progress", updated_hours_ago=10)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 0

    def test_in_progress_no_activity_stuck(self) -> None:
        config = _make_config(no_activity_hours=8)
        api = _mock_api(
            comments=[
                {
                    "created_at": (
                        datetime.now(UTC) - timedelta(hours=10)
                    ).isoformat(),
                    "message": "some update",
                }
            ]
        )
        tasks = [_make_task(status="in_progress", updated_hours_ago=9)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 1
        assert "no activity" in results[0].reason

    def test_review_stuck_when_over_threshold(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [_make_task(status="review", updated_hours_ago=13)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 1
        assert results[0].status == "review"

    def test_review_not_stuck_when_under_threshold(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [_make_task(status="review", updated_hours_ago=6)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 0

    def test_blocked_stuck_without_blocker_comment(self) -> None:
        config = _make_config()
        api = _mock_api(comments=[{"message": "some other comment"}])
        tasks = [_make_task(status="blocked", updated_hours_ago=2)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 1
        assert results[0].status == "blocked"
        assert "without blocker escalation" in results[0].reason

    def test_blocked_not_stuck_with_blocker_comment(self) -> None:
        config = _make_config()
        api = _mock_api(
            comments=[{"message": "mcon workflow blocker: cannot proceed"}]
        )
        tasks = [_make_task(status="blocked", updated_hours_ago=2)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 0

    def test_blocked_not_stuck_when_under_threshold(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [_make_task(status="blocked", updated_hours_ago=0.5)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 0

    def test_inbox_stuck_when_over_threshold(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [_make_task(status="inbox", updated_hours_ago=0, created_hours_ago=49)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 1
        assert results[0].status == "inbox"

    def test_inbox_not_stuck_when_under_threshold(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [_make_task(status="inbox", updated_hours_ago=0, created_hours_ago=24)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 0

    def test_inbox_backlog_excluded(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [
            _make_task(
                status="inbox",
                updated_hours_ago=0,
                created_hours_ago=100,
                tags=[{"name": "backlog"}],
            )
        ]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 0

    def test_done_tasks_ignored(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [_make_task(status="done", updated_hours_ago=100)]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 0

    def test_multiple_stuck_tasks(self) -> None:
        config = _make_config()
        api = _mock_api()
        tasks = [
            _make_task(task_id="t1", status="in_progress", updated_hours_ago=25),
            _make_task(task_id="t2", status="review", updated_hours_ago=13),
            _make_task(task_id="t3", status="done", updated_hours_ago=100),
        ]

        results = detect_stuck_tasks(tasks, "Board", "b1", config, api, MagicMock())

        assert len(results) == 2
        stuck_ids = {r.task_id for r in results}
        assert stuck_ids == {"t1", "t2"}


# ── Config loading tests ─────────────────────────────────────────────


class TestLoadConfig:
    def test_load_defaults_when_file_missing(self, tmp_path: Path) -> None:
        config = load_config(tmp_path / "nonexistent.json")

        assert config.base_url == "http://localhost:8002"
        assert config.management_board_id == "dd95369d-1497-41f2-8aeb-e06b51b63162"
        assert config.thresholds["in_progress_hours"] == 24

    def test_load_from_file(self, tmp_path: Path) -> None:
        config_file = tmp_path / "config.json"
        config_file.write_text(
            json.dumps(
                {
                    "monitoring": {"base_url": "http://custom:9000", "dry_run": True},
                    "thresholds": {"in_progress_hours": 48, "review_hours": 24},
                    "escalation": {"management_board_id": "custom-board-id"},
                }
            )
        )

        config = load_config(config_file)

        assert config.base_url == "http://custom:9000"
        assert config.dry_run is True
        assert config.thresholds["in_progress_hours"] == 48
        assert config.thresholds["review_hours"] == 24
        assert config.management_board_id == "custom-board-id"
        # blocked_hours should keep default
        assert config.thresholds["blocked_hours"] == 1


# ── State management tests ───────────────────────────────────────────


class TestStateManagement:
    def test_load_empty_state(self, tmp_path: Path) -> None:
        states = load_state(tmp_path / "nonexistent.json")
        assert states == {}

    def test_save_and_load_state(self, tmp_path: Path) -> None:
        state_file = tmp_path / "state.json"
        states = {
            "task-1": DedupState(
                source_task_id="task-1",
                investigation_task_id="inv-1",
                created_at=datetime.now(UTC).isoformat(),
            )
        }

        save_state(state_file, states)
        loaded = load_state(state_file)

        assert len(loaded) == 1
        assert loaded["task-1"].investigation_task_id == "inv-1"

    def test_prune_stale_state(self) -> None:
        now = datetime.now(UTC)
        states = {
            "recent": DedupState(
                source_task_id="recent",
                investigation_task_id="inv-recent",
                created_at=(now - timedelta(hours=1)).isoformat(),
            ),
            "stale": DedupState(
                source_task_id="stale",
                investigation_task_id="inv-stale",
                created_at=(now - timedelta(hours=100)).isoformat(),
            ),
        }

        pruned = prune_stale_state(states, stale_hours=48)

        assert "recent" in pruned
        assert "stale" not in pruned


# ── Description builder tests ────────────────────────────────────────


class TestBuildDescription:
    def test_description_contains_key_fields(self) -> None:
        stuck = StuckResult(
            task_id="abc-123",
            task_title="Fix the thing",
            board_id="board-1",
            board_name="Sysadmin",
            status="in_progress",
            reason="in_progress for 26.0h (threshold: 24h)",
            updated_at="2026-04-28T10:00:00Z",
            created_at="2026-04-27T10:00:00Z",
            assigned_agent_id="agent-1",
            assignee="Worker",
            in_progress_at="2026-04-28T08:00:00Z",
        )
        config = MonitorConfig()

        desc = build_investigation_description(stuck, config)

        assert "abc-123" in desc
        assert "Fix the thing" in desc
        assert "Sysadmin" in desc
        assert "in_progress" in desc
        assert "agent-1" in desc
        assert "Auto-generated" in desc


# ── Duration formatting tests ────────────────────────────────────────


class TestFormatDuration:
    def test_minutes(self) -> None:
        assert format_duration_hours(0.5) == "30m"

    def test_hours(self) -> None:
        assert format_duration_hours(6) == "6h"

    def test_days(self) -> None:
        assert format_duration_hours(36) == "1.5d"


# ── Auth resolution tests ────────────────────────────────────────────


class TestAuthResolution:
    def test_agent_token_preferred(self) -> None:
        with patch.dict("os.environ", {"AUTH_TOKEN": "agent-tok", "LOCAL_AUTH_TOKEN": "user-tok"}):
            headers = resolve_auth_headers()
            assert headers["X-Agent-Token"] == "agent-tok"

    def test_fallback_to_local_auth(self) -> None:
        with patch.dict("os.environ", {"LOCAL_AUTH_TOKEN": "user-tok"}, clear=True):
            headers = resolve_auth_headers()
            assert headers["Authorization"] == "Bearer user-tok"

    def test_empty_when_no_tokens(self) -> None:
        with patch.dict("os.environ", {}, clear=True):
            headers = resolve_auth_headers()
            assert headers == {}


# ── Investigation task tests ─────────────────────────────────────────


class TestInvestigationTaskCreation:
    def test_title_format(self) -> None:
        from monitor_stuck_tasks import create_investigation_task

        stuck = StuckResult(
            task_id="abc-123",
            task_title="Fix the thing",
            board_id="board-1",
            board_name="Sysadmin",
            status="in_progress",
            reason="in_progress for 26.0h",
            updated_at=(datetime.now(UTC) - timedelta(hours=26)).isoformat(),
            created_at="2026-04-27T10:00:00Z",
            assigned_agent_id="agent-1",
            assignee="Worker",
            in_progress_at="2026-04-28T08:00:00Z",
        )
        config = MonitorConfig(dry_run=True)
        api = MagicMock()
        logger = MagicMock()

        create_investigation_task(stuck, config, api, logger)

        # Dry run should not call API
        api.create_task.assert_not_called()

    def test_creates_task_when_not_dry_run(self) -> None:
        from monitor_stuck_tasks import create_investigation_task

        stuck = StuckResult(
            task_id="abc-123",
            task_title="Fix the thing",
            board_id="board-1",
            board_name="Sysadmin",
            status="in_progress",
            reason="in_progress for 26.0h",
            updated_at=(datetime.now(UTC) - timedelta(hours=26)).isoformat(),
            created_at="2026-04-27T10:00:00Z",
            assigned_agent_id="agent-1",
            assignee="Worker",
            in_progress_at="2026-04-28T08:00:00Z",
        )
        config = MonitorConfig(dry_run=False)
        api = MagicMock()
        api.create_task.return_value = {"id": "inv-1", "title": "[STUCK] ..."}
        logger = MagicMock()

        result = create_investigation_task(stuck, config, api, logger)

        api.create_task.assert_called_once()
        call_args = api.create_task.call_args
        assert call_args[0][0] == config.management_board_id
        payload = call_args[0][1]
        assert "[STUCK]" in payload["title"]
        assert payload["priority"] == "high"
        assert result == {"id": "inv-1", "title": "[STUCK] ..."}
