"""Crontab generation for GUI-managed utility jobs."""

from __future__ import annotations

import json
import os
import re
import shlex
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

from app.core.config import settings
from app.core.logging import get_logger
from app.core.time import utcnow
from app.db import crud
from app.db.session import async_session_maker
from app.models.utility_jobs import UtilityJob
from app.services.cron_gate import render_gated_cron_command
from app.services.queue import (
    QueuedTask,
    enqueue_task,
)
from app.services.queue import requeue_if_failed as generic_requeue_if_failed

logger = get_logger(__name__)

TASK_TYPE = "utility_job_crontab"
CRONTAB_DIR = os.getenv("MC_CRONTAB_DIR", "/etc/cron.d")
CRONTAB_PREFIX = "mission-control-job-"
CRON_USER = os.getenv("MC_CRON_USER", "cronjev")
LOG_DIR = os.getenv("MC_UTILITY_JOB_LOG_DIR", "/home/cronjev/.openclaw/logs/jobs")
DEFAULT_WORKDIR = os.getenv("MC_UTILITY_JOB_WORKDIR", "/home/cronjev/mission-control-tfsmrt")
SCRIPT_MAP_ENV = "MC_UTILITY_JOB_SCRIPTS_JSON"
SCRIPT_FILE_ENV = "MC_UTILITY_JOB_SCRIPTS_FILE"
SCRIPT_KEY_RE = re.compile(r"^[a-zA-Z0-9_.-]+$")

_DEFAULT_SCRIPT_OPTIONS: dict[str, dict[str, str | None]] = {
    "daily_conversation_review": {
        "label": "Daily conversation review",
        "description": "Compile conversation context and create the daily review task.",
        "command": "/home/cronjev/mission-control-tfsmrt/scripts/jobs/daily-conversation-review.ps1",
    },
}


@dataclass(frozen=True)
class UtilityJobCrontabTask:
    job_id: UUID
    action: str
    changed_at: datetime
    attempts: int = 0


def _resolve_project_root() -> Path:
    """Resolve the project root directory.

    The project root contains the `config/` directory.
    In Docker: /app (file at /app/app/services/...)
    Locally: /path/to/repo (file at /path/to/repo/backend/app/services/...)
    """
    current = Path(__file__).resolve()
    # Check parents[2] (Docker layout: /app/app/services -> /app)
    candidate = current.parents[2]
    if (candidate / "config").is_dir():
        return candidate
    # Fallback: check parents[3] (local layout: .../backend/app/services -> repo root)
    candidate = current.parents[3]
    if (candidate / "config").is_dir():
        return candidate
    # Last resort: walk up to filesystem root
    for parent in [current.parents[4], current.parents[5]]:
        if (parent / "config").is_dir():
            return parent
    raise FileNotFoundError(f"Could not locate project root (searched parents of {__file__})")


def _load_script_options() -> dict[str, dict[str, str | None]]:
    # File takes precedence over inline JSON env var
    script_file = os.getenv(SCRIPT_FILE_ENV)
    if script_file:
        path = Path(script_file).expanduser()
        # If relative, resolve against project root
        if not path.is_absolute():
            project_root = _resolve_project_root()
            path = project_root / path
        if not path.exists():
            raise FileNotFoundError(
                f"Utility job scripts file not found: {script_file} (resolved to {path})"
            )
        try:
            raw = path.read_text(encoding="utf-8")
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Utility job scripts file must be valid JSON: {exc}") from exc
    else:
        raw = os.getenv(SCRIPT_MAP_ENV)
        if not raw:
            return _DEFAULT_SCRIPT_OPTIONS
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{SCRIPT_MAP_ENV} must be valid JSON: {exc}") from exc

    if not isinstance(parsed, dict):
        raise ValueError("Utility job scripts must be a JSON object")

    options: dict[str, dict[str, str | None]] = {}
    for key, value in parsed.items():
        if not isinstance(key, str) or not SCRIPT_KEY_RE.match(key):
            raise ValueError(f"Invalid utility job script key: {key!r}")
        if isinstance(value, str):
            options[key] = {
                "label": key.replace("_", " ").title(),
                "description": None,
                "command": value,
            }
            continue
        if not isinstance(value, dict):
            raise ValueError(f"Utility job script {key!r} must be a string or object")
        command = value.get("command")
        if not isinstance(command, str) or not command.strip():
            raise ValueError(f"Utility job script {key!r} requires a command")
        label = value.get("label")
        description = value.get("description")
        options[key] = {
            "label": label if isinstance(label, str) and label.strip() else key,
            "description": description if isinstance(description, str) else None,
            "command": command.strip(),
        }
    return options


def script_options() -> list[dict[str, str | None]]:
    return [
        {"key": key, "label": value["label"], "description": value["description"]}
        for key, value in sorted(_load_script_options().items())
    ]


def validate_script_key(script_key: str) -> None:
    if not SCRIPT_KEY_RE.match(script_key):
        raise ValueError(
            "Script key may only contain letters, numbers, dashes, dots, and underscores"
        )
    if script_key not in _load_script_options():
        raise ValueError(f"Script key is not allowlisted: {script_key}")


def validate_cron_expression(expression: str) -> None:
    fields = expression.split()
    if len(fields) != 5:
        raise ValueError("Cron expression must use exactly five fields")
    if any(any(char in field for char in [";", "&", "|", "`", "$", "\\"]) for field in fields):
        raise ValueError("Cron expression contains unsupported shell metacharacters")


def decode_utility_job_crontab_task(task: QueuedTask) -> UtilityJobCrontabTask:
    payload = task.payload
    changed_at_str = payload.get("changed_at") or task.created_at.isoformat()
    changed_at = (
        datetime.fromisoformat(changed_at_str)
        if isinstance(changed_at_str, str)
        else datetime.now(UTC)
    )
    return UtilityJobCrontabTask(
        job_id=UUID(payload["job_id"]),
        action=str(payload.get("action") or "sync"),
        changed_at=changed_at,
        attempts=task.attempts,
    )


def _crontab_file_path(job_id: UUID) -> Path:
    return Path(CRONTAB_DIR) / f"{CRONTAB_PREFIX}{str(job_id)[:8]}"


def _to_ps_param(key: str) -> str:
    """Convert snake_case or kebab-case to PascalCase for PowerShell parameters."""
    return "".join(part.capitalize() for part in key.replace("-", "_").split("_"))


def _render_command(job: UtilityJob) -> str:
    options = _load_script_options()
    command = str(options[job.script_key]["command"]).strip()
    quoted_command: list[str]
    is_powershell = command.endswith(".ps1")
    if is_powershell:
        quoted_command = ["pwsh", "-NoProfile", "-File", shlex.quote(command)]
    else:
        quoted_command = [shlex.quote(command)]

    # Add board/agent scope args
    if job.board_id is not None:
        key = "-BoardId" if is_powershell else "--board-id"
        quoted_command.extend([key, shlex.quote(str(job.board_id))])
    if job.agent_id is not None:
        key = "-AgentId" if is_powershell else "--agent-id"
        quoted_command.extend([key, shlex.quote(str(job.agent_id))])

    # Add custom JSON args
    for key, value in sorted((job.args or {}).items()):
        if not isinstance(key, str) or not SCRIPT_KEY_RE.match(key):
            raise ValueError(f"Invalid argument key: {key!r}")
        if value is None:
            continue
        if is_powershell:
            param_key = f"-{_to_ps_param(key)}"
        else:
            param_key = f"--{key}"
        quoted_command.extend([param_key, shlex.quote(str(value))])

    return " ".join(quoted_command)


def _build_crontab_content(job: UtilityJob) -> str:
    validate_cron_expression(job.cron_expression)
    validate_script_key(job.script_key)
    log_file = f"{LOG_DIR}/job-{str(job.id)[:8]}.$(date +\\%Y\\%m\\%d).log"
    command = _render_command(job)
    enabled_prefix = "" if job.enabled else "# disabled: "
    cron_command = render_gated_cron_command(
        workdir=DEFAULT_WORKDIR,
        command=command,
        log_dir=LOG_DIR,
        log_file=log_file,
    )
    cron_line = f"{enabled_prefix}{job.cron_expression} {CRON_USER} {cron_command}"
    return "\n".join(
        [
            "# Mission Control utility job",
            f"# Job: {job.name} ({job.id})",
            f"# Script key: {job.script_key}",
            f"# Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
            "# DO NOT EDIT MANUALLY - changes will be overwritten",
            "",
            cron_line,
            "",
        ]
    )


async def sync_utility_job_crontab(job_id: UUID) -> tuple[str, Path | None]:
    async with async_session_maker() as session:
        job = await crud.get_by_id(session, UtilityJob, job_id)
        if job is None:
            return "", await remove_utility_job_crontab(job_id)
        content = _build_crontab_content(job)
        Path(CRONTAB_DIR).mkdir(parents=True, exist_ok=True)
        file_path = _crontab_file_path(job.id)
        file_path.write_text(content, encoding="utf-8")
        os.chmod(file_path, 0o644)
        job.crontab_path = str(file_path)
        job.last_generated_at = utcnow()
        await crud.save(session, job)
        logger.info(
            "utility_job_crontab.generated",
            extra={
                "job_id": str(job.id),
                "file": str(file_path),
                "script_key": job.script_key,
            },
        )
        return content, file_path


async def remove_utility_job_crontab(job_id: UUID) -> Path | None:
    file_path = _crontab_file_path(job_id)
    if file_path.exists():
        file_path.unlink()
        logger.info(
            "utility_job_crontab.removed",
            extra={"job_id": str(job_id), "removed_file": str(file_path)},
        )
        return file_path
    return None


async def process_utility_job_crontab_task(task: QueuedTask) -> None:
    decoded = decode_utility_job_crontab_task(task)
    if decoded.action == "delete":
        await remove_utility_job_crontab(decoded.job_id)
        return
    await sync_utility_job_crontab(decoded.job_id)


def enqueue_utility_job_crontab(
    job_id: UUID,
    *,
    action: str = "sync",
    changed_at: datetime | None = None,
) -> bool:
    payload = UtilityJobCrontabTask(
        job_id=job_id,
        action=action,
        changed_at=changed_at or datetime.now(UTC),
    )
    try:
        task = QueuedTask(
            task_type=TASK_TYPE,
            payload={
                "job_id": str(payload.job_id),
                "action": payload.action,
                "changed_at": payload.changed_at.isoformat(),
            },
            created_at=payload.changed_at,
            attempts=payload.attempts,
        )
        enqueue_task(task, settings.rq_queue_name, redis_url=settings.rq_redis_url)
        return True
    except Exception as exc:
        logger.warning(
            "utility_job_crontab.queue.enqueue_failed",
            extra={"job_id": str(job_id), "action": action, "error": str(exc)},
        )
        return False


def requeue_if_failed(task: QueuedTask, *, delay_seconds: float = 0) -> bool:
    decoded = decode_utility_job_crontab_task(task)
    retry_task = QueuedTask(
        task_type=TASK_TYPE,
        payload={
            "job_id": str(decoded.job_id),
            "action": decoded.action,
            "changed_at": decoded.changed_at.isoformat(),
        },
        created_at=decoded.changed_at,
        attempts=decoded.attempts,
    )
    return generic_requeue_if_failed(
        retry_task,
        settings.rq_queue_name,
        max_retries=settings.rq_dispatch_max_retries,
        redis_url=settings.rq_redis_url,
        delay_seconds=delay_seconds,
    )
