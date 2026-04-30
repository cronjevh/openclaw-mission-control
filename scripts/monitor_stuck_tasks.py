#!/usr/bin/env python3
"""Stuck-task monitoring routine for Mission Control.

Detects tasks that have been in transitional states (in_progress, review,
blocked, inbox) beyond configurable thresholds and creates investigation
tasks on the Mission Control Management board.

Usage:
    python scripts/monitor_stuck_tasks.py [OPTIONS]

Options:
    --config PATH       Path to JSON config file (default: ~/.openclaw/monitor-stuck-tasks/config.json)
    --board-id UUID     Scope monitoring to a single board (optional)
    --agent-id UUID     Agent ID for agent-token auth (optional)
    --dry-run           Log findings without creating investigation tasks
    --verbose           Enable debug-level logging
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

try:
    import httpx
except ImportError:
    print("ERROR: httpx is required. Install with: pip install httpx", file=sys.stderr)
    sys.exit(1)

LOG_FORMAT = "[%(asctime)s] %(levelname)s %(message)s"
DEFAULT_CONFIG_DIR = Path.home() / ".openclaw" / "monitor-stuck-tasks"
DEFAULT_CONFIG_FILE = DEFAULT_CONFIG_DIR / "config.json"
DEFAULT_STATE_FILE = DEFAULT_CONFIG_DIR / "state.json"
DEFAULT_LOG_DIR = Path.home() / ".openclaw" / "logs"

DEFAULT_THRESHOLDS = {
    "in_progress_hours": 24,
    "review_hours": 12,
    "blocked_hours": 1,
    "inbox_hours": 48,
}

DEFAULT_MANAGEMENT_BOARD_ID = "dd95369d-1497-41f2-8aeb-e06b51b63162"

MONITORED_STATUSES = ("in_progress", "review", "blocked", "inbox")


# ── Data classes ─────────────────────────────────────────────────────


@dataclass
class MonitorConfig:
    base_url: str = "http://localhost:8002"
    management_board_id: str = DEFAULT_MANAGEMENT_BOARD_ID
    thresholds: dict[str, float] = field(default_factory=lambda: dict(DEFAULT_THRESHOLDS))
    board_whitelist: list[str] = field(default_factory=list)
    exclude_tags: list[str] = field(default_factory=lambda: ["archived", "paused"])
    dry_run: bool = False
    default_assignee: str | None = None
    priority: str = "high"
    tags: list[str] = field(
        default_factory=lambda: ["stuck-task", "auto-escalated", "needs-attention"]
    )
    notify_source_task: bool = True
    dedup_hours: int = 24
    no_activity_hours: float = 8
    stale_state_hours: int = 48


@dataclass
class StuckResult:
    task_id: str
    task_title: str
    board_id: str
    board_name: str
    status: str
    reason: str
    updated_at: str
    created_at: str
    assigned_agent_id: str | None
    assignee: str | None
    in_progress_at: str | None
    depends_on_task_ids: list[str] = field(default_factory=list)
    tags: list[dict[str, Any]] = field(default_factory=list)
    custom_field_values: dict[str, Any] = field(default_factory=dict)


@dataclass
class DedupState:
    source_task_id: str
    investigation_task_id: str
    created_at: str
    last_comment_at: str | None = None


# ── Logging setup ────────────────────────────────────────────────────


def setup_logging(*, verbose: bool = False, log_file: Path | None = None) -> logging.Logger:
    logger = logging.getLogger("monitor_stuck_tasks")
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    formatter = logging.Formatter(LOG_FORMAT)

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(formatter)
    logger.addHandler(console)

    if log_file:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(log_file, encoding="utf-8")
        fh.setFormatter(formatter)
        logger.addHandler(fh)

    return logger


# ── Config loading ───────────────────────────────────────────────────


def load_config(config_path: Path) -> MonitorConfig:
    config = MonitorConfig()
    if not config_path.exists():
        return config

    with open(config_path, encoding="utf-8") as f:
        data = json.load(f)

    monitoring = data.get("monitoring", {})
    config.base_url = monitoring.get("base_url", config.base_url)
    config.dry_run = monitoring.get("dry_run", config.dry_run)
    config.dedup_hours = monitoring.get("dedup_hours", config.dedup_hours)
    config.no_activity_hours = monitoring.get("no_activity_hours", config.no_activity_hours)
    config.stale_state_hours = monitoring.get("stale_state_hours", config.stale_state_hours)

    thresholds = data.get("thresholds", {})
    config.thresholds.update(
        {k: float(v) for k, v in thresholds.items() if k in DEFAULT_THRESHOLDS}
    )

    boards = data.get("boards", {})
    config.board_whitelist = boards.get("whitelist", [])
    config.exclude_tags = boards.get("exclude_tags", config.exclude_tags)

    escalation = data.get("escalation", {})
    config.management_board_id = escalation.get(
        "management_board_id", config.management_board_id
    )
    config.default_assignee = escalation.get("default_assignee")
    config.priority = escalation.get("priority", config.priority)
    config.tags = escalation.get("tags", config.tags)
    config.notify_source_task = escalation.get("notify_source_task", config.notify_source_task)

    return config


# ── Auth resolution ──────────────────────────────────────────────────


def resolve_auth_headers() -> dict[str, str]:
    """Resolve auth headers from environment variables.

    Prefers AUTH_TOKEN (agent auth) over LOCAL_AUTH_TOKEN (bearer auth).
    """
    agent_token = os.environ.get("AUTH_TOKEN")
    if agent_token:
        return {"X-Agent-Token": agent_token, "Content-Type": "application/json"}

    local_token = os.environ.get("LOCAL_AUTH_TOKEN")
    if local_token:
        return {"Authorization": f"Bearer {local_token}", "Content-Type": "application/json"}

    return {}


# ── API helpers ──────────────────────────────────────────────────────


class MissionControlAPI:
    def __init__(
        self,
        base_url: str,
        headers: dict[str, str],
        logger: logging.Logger,
        timeout: float = 30.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.headers = headers
        self.logger = logger
        self.client = httpx.Client(
            base_url=self.base_url,
            headers=self.headers,
            timeout=timeout,
        )

    def close(self) -> None:
        self.client.close()

    def _get_paginated(self, path: str, params: dict[str, Any] | None = None) -> list[dict]:
        """Fetch all items from a paginated endpoint."""
        items: list[dict] = []
        offset = 0
        limit = 50
        while True:
            query = {"limit": limit, "offset": offset}
            if params:
                query.update(params)
            resp = self.client.get(path, params=query)
            resp.raise_for_status()
            data = resp.json()
            page_items = data.get("items", [])
            items.extend(page_items)
            total = data.get("total", 0)
            offset += limit
            if offset >= total or not page_items:
                break
        return items

    def list_boards(self) -> list[dict]:
        """List all boards visible to the caller."""
        return self._get_paginated("/api/v1/boards")

    def list_agent_boards(self) -> list[dict]:
        """List boards via agent API."""
        return self._get_paginated("/api/v1/agent/boards")

    def list_tasks(
        self, board_id: str, status: str | None = None, limit: int = 100
    ) -> list[dict]:
        """List tasks on a board, optionally filtered by status."""
        params: dict[str, Any] = {}
        if status:
            params["status"] = status
        items: list[dict] = []
        offset = 0
        while True:
            query = {"limit": min(limit - len(items), 50), "offset": offset, **params}
            resp = self.client.get(
                f"/api/v1/boards/{board_id}/tasks", params=query
            )
            resp.raise_for_status()
            data = resp.json()
            page_items = data.get("items", [])
            items.extend(page_items)
            total = data.get("total", 0)
            offset += len(page_items)
            if offset >= total or not page_items or len(items) >= limit:
                break
        return items

    def list_comments(self, board_id: str, task_id: str) -> list[dict]:
        """List comments on a task."""
        resp = self.client.get(
            f"/api/v1/boards/{board_id}/tasks/{task_id}/comments",
            params={"limit": 50},
        )
        resp.raise_for_status()
        data = resp.json()
        return data.get("items", [])

    def get_task(self, board_id: str, task_id: str) -> dict:
        """Get a single task."""
        resp = self.client.get(f"/api/v1/boards/{board_id}/tasks/{task_id}")
        resp.raise_for_status()
        return resp.json()

    def create_task(self, board_id: str, payload: dict) -> dict:
        """Create a task on a board."""
        resp = self.client.post(f"/api/v1/boards/{board_id}/tasks", json=payload)
        resp.raise_for_status()
        return resp.json()

    def create_comment(self, board_id: str, task_id: str, message: str) -> dict:
        """Create a comment on a task."""
        resp = self.client.post(
            f"/api/v1/boards/{board_id}/tasks/{task_id}/comments",
            json={"message": message},
        )
        resp.raise_for_status()
        return resp.json()


# ── State management ─────────────────────────────────────────────────


def load_state(state_file: Path) -> dict[str, DedupState]:
    if not state_file.exists():
        return {}
    try:
        with open(state_file, encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}

    states: dict[str, DedupState] = {}
    for task_id, entry in data.items():
        states[task_id] = DedupState(
            source_task_id=entry["source_task_id"],
            investigation_task_id=entry["investigation_task_id"],
            created_at=entry["created_at"],
            last_comment_at=entry.get("last_comment_at"),
        )
    return states


def save_state(state_file: Path, states: dict[str, DedupState]) -> None:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    data = {}
    for task_id, state in states.items():
        data[task_id] = {
            "source_task_id": state.source_task_id,
            "investigation_task_id": state.investigation_task_id,
            "created_at": state.created_at,
            "last_comment_at": state.last_comment_at,
        }
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def prune_stale_state(
    states: dict[str, DedupState], stale_hours: int
) -> dict[str, DedupState]:
    cutoff = datetime.now(UTC) - timedelta(hours=stale_hours)
    pruned: dict[str, DedupState] = {}
    for task_id, state in states.items():
        created = datetime.fromisoformat(state.created_at)
        if created.tzinfo is None:
            created = created.replace(tzinfo=UTC)
        if created > cutoff:
            pruned[task_id] = state
    return pruned


# ── Stuck detection ──────────────────────────────────────────────────


def parse_iso_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt


def detect_stuck_tasks(
    tasks: list[dict],
    board_name: str,
    board_id: str,
    config: MonitorConfig,
    api: MissionControlAPI,
    logger: logging.Logger,
) -> list[StuckResult]:
    now = datetime.now(UTC)
    results: list[StuckResult] = []
    thresholds = config.thresholds

    for task in tasks:
        task_id = task["id"]
        status = task.get("status", "")
        updated_at = parse_iso_datetime(task.get("updated_at"))
        created_at = parse_iso_datetime(task.get("created_at"))

        if updated_at is None:
            continue

        age_hours = (now - updated_at).total_seconds() / 3600

        tags = task.get("tags", [])
        custom_fields = task.get("custom_field_values") or {}

        result: StuckResult | None = None

        if status == "in_progress":
            threshold = thresholds.get("in_progress_hours", 24)
            if age_hours >= threshold:
                result = StuckResult(
                    task_id=task_id,
                    task_title=task.get("title", ""),
                    board_id=board_id,
                    board_name=board_name,
                    status=status,
                    reason=f"in_progress for {age_hours:.1f}h (threshold: {threshold}h)",
                    updated_at=task.get("updated_at", ""),
                    created_at=task.get("created_at", ""),
                    assigned_agent_id=task.get("assigned_agent_id"),
                    assignee=task.get("assignee"),
                    in_progress_at=task.get("in_progress_at"),
                    depends_on_task_ids=[
                        str(d) for d in task.get("depends_on_task_ids", [])
                    ],
                    tags=tags,
                    custom_field_values=custom_fields,
                )
            else:
                no_activity_threshold = config.no_activity_hours
                if age_hours >= no_activity_threshold:
                    try:
                        comments = api.list_comments(board_id, task_id)
                        if comments:
                            latest_comment_time = max(
                                parse_iso_datetime(c.get("created_at")) or datetime.min.replace(tzinfo=UTC)
                                for c in comments
                            )
                            comment_age = (now - latest_comment_time).total_seconds() / 3600
                            if comment_age >= no_activity_threshold:
                                result = StuckResult(
                                    task_id=task_id,
                                    task_title=task.get("title", ""),
                                    board_id=board_id,
                                    board_name=board_name,
                                    status=status,
                                    reason=f"no activity for {comment_age:.1f}h (threshold: {no_activity_threshold}h)",
                                    updated_at=task.get("updated_at", ""),
                                    created_at=task.get("created_at", ""),
                                    assigned_agent_id=task.get("assigned_agent_id"),
                                    assignee=task.get("assignee"),
                                    in_progress_at=task.get("in_progress_at"),
                                    depends_on_task_ids=[
                                        str(d) for d in task.get("depends_on_task_ids", [])
                                    ],
                                    tags=tags,
                                    custom_field_values=custom_fields,
                                )
                    except Exception as exc:
                        logger.warning("Failed to fetch comments for task %s: %s", task_id, exc)

        elif status == "review":
            threshold = thresholds.get("review_hours", 12)
            if age_hours >= threshold:
                result = StuckResult(
                    task_id=task_id,
                    task_title=task.get("title", ""),
                    board_id=board_id,
                    board_name=board_name,
                    status=status,
                    reason=f"review for {age_hours:.1f}h (threshold: {threshold}h)",
                    updated_at=task.get("updated_at", ""),
                    created_at=task.get("created_at", ""),
                    assigned_agent_id=task.get("assigned_agent_id"),
                    assignee=task.get("assignee"),
                    in_progress_at=task.get("in_progress_at"),
                    depends_on_task_ids=[
                        str(d) for d in task.get("depends_on_task_ids", [])
                    ],
                    tags=tags,
                    custom_field_values=custom_fields,
                )

        elif status == "blocked":
            threshold = thresholds.get("blocked_hours", 1)
            has_blocker_comment = False
            try:
                comments = api.list_comments(board_id, task_id)
                has_blocker_comment = any(
                    "mcon workflow blocker" in (c.get("message") or "").lower()
                    for c in comments
                )
            except Exception as exc:
                logger.warning("Failed to fetch comments for blocked task %s: %s", task_id, exc)

            if age_hours >= threshold and not has_blocker_comment:
                result = StuckResult(
                    task_id=task_id,
                    task_title=task.get("title", ""),
                    board_id=board_id,
                    board_name=board_name,
                    status=status,
                    reason=f"blocked for {age_hours:.1f}h without blocker escalation comment",
                    updated_at=task.get("updated_at", ""),
                    created_at=task.get("created_at", ""),
                    assigned_agent_id=task.get("assigned_agent_id"),
                    assignee=task.get("assignee"),
                    in_progress_at=task.get("in_progress_at"),
                    depends_on_task_ids=[
                        str(d) for d in task.get("depends_on_task_ids", [])
                    ],
                    tags=tags,
                    custom_field_values=custom_fields,
                )

        elif status == "inbox":
            is_backlog = any(
                t.get("name", "").lower() == "backlog" if isinstance(t, dict) else str(t).lower() == "backlog"
                for t in tags
            )
            if not is_backlog and created_at:
                inbox_age = (now - created_at).total_seconds() / 3600
                threshold = thresholds.get("inbox_hours", 48)
                if inbox_age >= threshold:
                    result = StuckResult(
                        task_id=task_id,
                        task_title=task.get("title", ""),
                        board_id=board_id,
                        board_name=board_name,
                        status=status,
                        reason=f"inbox for {inbox_age:.1f}h unassigned (threshold: {threshold}h)",
                        updated_at=task.get("updated_at", ""),
                        created_at=task.get("created_at", ""),
                        assigned_agent_id=task.get("assigned_agent_id"),
                        assignee=task.get("assignee"),
                        in_progress_at=task.get("in_progress_at"),
                        depends_on_task_ids=[
                            str(d) for d in task.get("depends_on_task_ids", [])
                        ],
                        tags=tags,
                        custom_field_values=custom_fields,
                    )

        if result:
            results.append(result)

    return results


# ── Investigation task creation ──────────────────────────────────────


def build_investigation_description(stuck: StuckResult, config: MonitorConfig) -> str:
    now_str = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S UTC")
    deps_str = ", ".join(stuck.depends_on_task_ids) if stuck.depends_on_task_ids else "none"
    assignee_str = stuck.assignee or "unassigned"
    if stuck.assigned_agent_id:
        assignee_str += f" ({stuck.assigned_agent_id})"

    return f"""## Stuck Task Detected

**Source Board:** {stuck.board_name} ({stuck.board_id})
**Source Task:** {stuck.task_title} (`{stuck.task_id}`)
**Status:** {stuck.status}
**Duration in status:** {stuck.reason}
**Assigned to:** {assignee_str}

### Why This Task Is Flagged

{stuck.reason}

### Diagnostic Context

- **Created:** {stuck.created_at}
- **Last updated:** {stuck.updated_at}
- **In progress since:** {stuck.in_progress_at or "N/A"}
- **Dependencies:** {deps_str}
- **Custom fields:** {json.dumps(stuck.custom_field_values, indent=2) if stuck.custom_field_values else "none"}

### Recommended Investigation Steps

1. Check if the worker agent is alive and responsive (heartbeat, session registry)
2. Review task comments for blockers or unanswered questions
3. If `blocked`: verify `mcon workflow blocker` was called; if not, escalate to lead
4. If `in_progress` > 24h: ask assignee for status update or reassign
5. If `review` > 12h: check lead availability; consider reassigning review
6. If dependency-blocked: unblock prerequisite tasks or adjust dependency graph

---
*Auto-generated by stuck-task monitor on {now_str}*
*Config: thresholds.in_progress={config.thresholds.get("in_progress_hours")}h, review={config.thresholds.get("review_hours")}h, blocked={config.thresholds.get("blocked_hours")}h*"""


def format_duration_hours(hours: float) -> str:
    if hours < 1:
        return f"{int(hours * 60)}m"
    if hours < 24:
        return f"{hours:.0f}h"
    days = hours / 24
    return f"{days:.1f}d"


def create_investigation_task(
    stuck: StuckResult,
    config: MonitorConfig,
    api: MissionControlAPI,
    logger: logging.Logger,
) -> dict | None:
    updated = parse_iso_datetime(stuck.updated_at) or datetime.now(UTC)
    duration = format_duration_hours(
        (datetime.now(UTC) - updated).total_seconds() / 3600
    )
    title = f"[STUCK] {stuck.board_name}: {stuck.task_title} [{stuck.status} for {duration}]"

    payload: dict[str, Any] = {
        "title": title[:200],
        "description": build_investigation_description(stuck, config),
        "priority": config.priority,
        "status": "inbox",
    }

    if config.default_assignee:
        payload["assigned_agent_id"] = config.default_assignee

    logger.info("Creating investigation task: %s", title)
    if config.dry_run:
        logger.info("[DRY RUN] Would create task: %s", json.dumps(payload, indent=2)[:500])
        return None

    try:
        result = api.create_task(config.management_board_id, payload)
        logger.info("Created investigation task: %s (id=%s)", title, result.get("id"))
        return result
    except Exception as exc:
        logger.error("Failed to create investigation task for %s: %s", stuck.task_id, exc)
        return None


def post_update_comment(
    investigation_task_id: str,
    stuck: StuckResult,
    config: MonitorConfig,
    api: MissionControlAPI,
    logger: logging.Logger,
) -> None:
    now_str = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S UTC")
    message = (
        f"**Monitor update** ({now_str})\n\n"
        f"Source task `{stuck.task_id}` is still {stuck.status}. "
        f"Reason: {stuck.reason}.\n"
        f"Last updated: {stuck.updated_at}."
    )
    if config.dry_run:
        logger.info("[DRY RUN] Would post comment on %s: %s", investigation_task_id, message[:200])
        return

    try:
        api.create_comment(config.management_board_id, investigation_task_id, message)
        logger.info("Posted update comment on investigation task %s", investigation_task_id)
    except Exception as exc:
        logger.error("Failed to post comment on %s: %s", investigation_task_id, exc)


def notify_source_task(
    stuck: StuckResult,
    investigation_task: dict,
    config: MonitorConfig,
    api: MissionControlAPI,
    logger: logging.Logger,
) -> None:
    if not config.notify_source_task:
        return
    if config.dry_run:
        logger.info("[DRY RUN] Would notify source task %s", stuck.task_id)
        return

    inv_title = investigation_task.get("title", "investigation task")
    inv_id = investigation_task.get("id", "unknown")
    message = (
        f"@worker @lead — This task has been flagged as potentially stuck. "
        f"An investigation has been opened: {inv_title} ({inv_id}).\n"
        f"Please update status or unblock within 4 hours."
    )
    try:
        api.create_comment(stuck.board_id, stuck.task_id, message)
        logger.info("Notified source task %s", stuck.task_id)
    except Exception as exc:
        logger.warning("Failed to notify source task %s: %s", stuck.task_id, exc)


# ── Board discovery ──────────────────────────────────────────────────


def discover_boards(
    config: MonitorConfig,
    api: MissionControlAPI,
    logger: logging.Logger,
) -> list[dict]:
    """Discover boards to monitor."""
    try:
        boards = api.list_boards()
    except Exception:
        logger.debug("User board list failed, trying agent API")
        try:
            boards = api.list_agent_boards()
        except Exception as exc:
            logger.error("Failed to list boards: %s", exc)
            return []

    operational_types = {"goal", "project"}
    result: list[dict] = []
    for board in boards:
        board_id = board.get("id", "")
        board_type = board.get("board_type", "")

        if config.board_whitelist and board_id not in config.board_whitelist:
            continue
        if board_type not in operational_types:
            continue

        result.append(board)

    logger.info("Discovered %d boards to monitor", len(result))
    return result


# ── Main monitoring loop ─────────────────────────────────────────────


def run_monitor(
    config: MonitorConfig,
    logger: logging.Logger,
    state_file: Path | None = None,
) -> int:
    """Run the stuck-task monitor. Returns the number of stuck tasks found."""
    auth_headers = resolve_auth_headers()
    if not auth_headers:
        logger.error("No auth token found. Set AUTH_TOKEN or LOCAL_AUTH_TOKEN.")
        return -1

    api = MissionControlAPI(config.base_url, auth_headers, logger)
    effective_state_file = state_file or DEFAULT_STATE_FILE

    try:
        states = load_state(effective_state_file)
        states = prune_stale_state(states, config.stale_state_hours)

        boards = discover_boards(config, api, logger)
        if not boards:
            logger.warning("No boards found to monitor")
            return 0

        total_stuck = 0
        total_investigations = 0

        for board in boards:
            board_id = board["id"]
            board_name = board.get("name", board_id)
            logger.info("Checking board: %s (%s)", board_name, board_id)

            try:
                all_tasks: list[dict] = []
                for status in MONITORED_STATUSES:
                    tasks = api.list_tasks(board_id, status=status, limit=100)
                    all_tasks.extend(tasks)

                seen_ids: set[str] = set()
                unique_tasks: list[dict] = []
                for t in all_tasks:
                    tid = t.get("id", "")
                    if tid not in seen_ids:
                        seen_ids.add(tid)
                        unique_tasks.append(t)

                stuck_tasks = detect_stuck_tasks(
                    unique_tasks, board_name, board_id, config, api, logger
                )
                total_stuck += len(stuck_tasks)

                for stuck in stuck_tasks:
                    logger.warning(
                        "STUCK: %s [%s] on %s — %s",
                        stuck.task_title,
                        stuck.status,
                        board_name,
                        stuck.reason,
                    )

                    existing = states.get(stuck.task_id)
                    if existing:
                        post_update_comment(
                            existing.investigation_task_id, stuck, config, api, logger
                        )
                        states[stuck.task_id] = DedupState(
                            source_task_id=existing.source_task_id,
                            investigation_task_id=existing.investigation_task_id,
                            created_at=existing.created_at,
                            last_comment_at=datetime.now(UTC).isoformat(),
                        )
                    else:
                        inv_task = create_investigation_task(stuck, config, api, logger)
                        if inv_task:
                            total_investigations += 1
                            states[stuck.task_id] = DedupState(
                                source_task_id=stuck.task_id,
                                investigation_task_id=inv_task["id"],
                                created_at=datetime.now(UTC).isoformat(),
                            )
                            notify_source_task(stuck, inv_task, config, api, logger)

            except Exception as exc:
                logger.error("Error processing board %s: %s", board_name, exc)

        save_state(effective_state_file, states)
        logger.info(
            "Monitor complete: %d stuck tasks found, %d new investigation tasks created",
            total_stuck,
            total_investigations,
        )
        return total_stuck

    finally:
        api.close()


# ── CLI entry point ──────────────────────────────────────────────────


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Mission Control stuck-task monitoring routine.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG_FILE,
        help="Path to JSON config file.",
    )
    parser.add_argument(
        "--board-id",
        type=str,
        default=None,
        help="Scope monitoring to a single board.",
    )
    parser.add_argument(
        "--agent-id",
        type=str,
        default=None,
        help="Agent ID for agent-token auth.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Log findings without creating investigation tasks.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable debug-level logging.",
    )
    parser.add_argument(
        "--state-file",
        type=Path,
        default=None,
        help="Path to state file for deduplication.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    log_dir = DEFAULT_LOG_DIR
    log_file = log_dir / f"stuck-task-monitor-{datetime.now().strftime('%Y%m%d')}.log"
    logger = setup_logging(verbose=args.verbose, log_file=log_file)

    config = load_config(args.config)
    if args.dry_run:
        config.dry_run = True
    if args.board_id:
        config.board_whitelist = [args.board_id]

    logger.info("=== Stuck-Task Monitor Start ===")
    logger.info("Config: %s", args.config)
    logger.info("Dry run: %s", config.dry_run)
    logger.info("Thresholds: %s", config.thresholds)

    result = run_monitor(config, logger, state_file=args.state_file)

    if result < 0:
        logger.error("Monitor failed")
        return 1

    logger.info("=== Stuck-Task Monitor Complete ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
