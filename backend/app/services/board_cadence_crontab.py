"""Crontab generation for Mission Control board cadence automation."""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import UUID

from app.core.config import settings
from app.core.logging import get_logger
from app.db import crud
from app.models.boards import Board
from app.db.session import async_session_maker
from app.services.queue import (
    QueuedTask,
    enqueue_task,
    requeue_if_failed as generic_requeue_if_failed,
)

logger = get_logger(__name__)

CRONTAB_DIR = os.getenv("MC_CRONTAB_DIR", "/etc/cron.d")
CRONTAB_PREFIX = "mission-control-board-"
WORKSPACE_BASE_DIR = os.getenv("MC_WORKSPACE_BASE_DIR", "/home/cronjev/.openclaw")
MCON_PATH = os.getenv("MC_MCON_PATH", "/home/cronjev/bin/mcon")
CRON_USER = os.getenv("MC_CRON_USER", "cronjev")
DISPATCH_LOG_DIR = os.getenv("MC_DISPATCH_LOG_DIR", "/home/cronjev/.openclaw/logs")


@dataclass(frozen=True)
class BoardCadenceCrontabTask:
    board_id: UUID
    changed_at: datetime
    attempts: int = 0


def decode_board_cadence_task(task: QueuedTask) -> BoardCadenceCrontabTask:
    payload = task.payload
    changed_at_str = (
        payload.get("changed_at") or task.created_at.isoformat()
        if hasattr(task, "created_at")
        else None
    )
    if isinstance(changed_at_str, str):
        changed_at = datetime.fromisoformat(changed_at_str)
    else:
        changed_at = datetime.now(UTC)
    return BoardCadenceCrontabTask(
        board_id=UUID(payload["board_id"]),
        changed_at=changed_at,
        attempts=task.attempts,
    )


def _format_crontab_schedule(cadence_minutes: int) -> str:
    return f"*/{cadence_minutes} * * * *"


def _build_crontab_content(board: Board, cadence_minutes: int) -> str:
    lines = [
        "# Mission Control board automation",
        f"# Board: {board.name} ({board.id})",
        f"# Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        "# DO NOT EDIT MANUALLY - changes will be overwritten",
        "",
    ]

    if cadence_minutes <= 0:
        lines.append("# Cadence not configured - no dispatch entries generated")
        lines.append("")
        return "\n".join(lines)

    if not board.gateway_id:
        lines.append(
            f"# ERROR: board has no gateway_id, cannot generate dispatch entry"
        )
        lines.append("")
        return "\n".join(lines)

    schedule = _format_crontab_schedule(cadence_minutes)
    gateway_workspace = f"{WORKSPACE_BASE_DIR}/workspace-gateway-{board.gateway_id}"
    log_dir = DISPATCH_LOG_DIR
    lines.append(
        f"{schedule} {CRON_USER} mkdir -p {log_dir} && cd {gateway_workspace} && {MCON_PATH} workflow dispatchboard --board {board.id} >> {log_dir}/dispatchboard-{str(board.id)[:8]}.$(date +\\%Y\\%m\\%d).log 2>&1"
    )

    lines.append("")
    return "\n".join(lines)


def _crontab_file_path(board_id: str) -> Path:
    short_id = board_id[:8]
    filename = f"{CRONTAB_PREFIX}{short_id}"
    return Path(CRONTAB_DIR) / filename


def validate_cadence(cadence: Any) -> tuple[bool, str]:
    if cadence is None:
        return True, ""

    try:
        cadence_int = int(cadence)
    except (ValueError, TypeError):
        return False, f"Cadence must be an integer, got {cadence!r}"

    if cadence_int <= 0:
        return False, f"Cadence must be positive, got {cadence_int}"

    if cadence_int > 1440:
        return False, f"Cadence cannot exceed 1440 minutes (24h), got {cadence_int}"

    return True, ""


async def generate_board_crontab(
    session: AsyncSession,
    board_id: UUID,
    *,
    dry_run: bool = False,
    crontab_dir: str | None = None,
) -> tuple[str, Path | None]:
    board = await crud.get_by_id(session, Board, board_id)
    if board is None:
        raise ValueError(f"Board not found: {board_id}")

    cadence = getattr(board, "cadence_minutes", None)

    if cadence is not None:
        valid, err = validate_cadence(cadence)
        if not valid:
            raise ValueError(f"Invalid cadence for board {board_id}: {err}")

    if cadence is None:
        output_dir = crontab_dir or CRONTAB_DIR
        file_path = Path(output_dir) / f"{CRONTAB_PREFIX}{str(board_id)[:8]}"
        if file_path.exists():
            file_path.unlink()
            logger.info(
                "board_cadence_crontab.removed",
                extra={"board_id": str(board_id), "removed_file": str(file_path)},
            )
        return "", None

    content = _build_crontab_content(board, cadence)

    if dry_run:
        logger.info(
            "board_cadence_crontab.generated.dry_run",
            extra={
                "board_id": str(board_id),
                "cadence": cadence,
                "gateway_id": str(board.gateway_id) if board.gateway_id else None,
            },
        )
        return content, None

    output_dir = crontab_dir or CRONTAB_DIR
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    file_path = _crontab_file_path(str(board_id))

    file_path.write_text(content, encoding="utf-8")

    os.chmod(file_path, 0o644)

    logger.info(
        "board_cadence_crontab.generated",
        extra={
            "board_id": str(board_id),
            "file": str(file_path),
            "cadence": cadence,
            "gateway_id": str(board.gateway_id) if board.gateway_id else None,
        },
    )
    return content, file_path


async def process_board_cadence_crontab_task(task: QueuedTask) -> None:
    board_task = decode_board_cadence_task(task)
    logger.info(
        "board_cadence_crontab.task.start",
        extra={
            "board_id": str(board_task.board_id),
            "changed_at": board_task.changed_at.isoformat(),
        },
    )
    try:
        from app.db.session import async_session_maker

        async with async_session_maker() as session:
            content, file_path = await generate_board_crontab(
                session, board_task.board_id
            )
        logger.info(
            "board_cadence_crontab.task.complete",
            extra={
                "board_id": str(board_task.board_id),
                "file": str(file_path) if file_path else "dry_run",
            },
        )
    except Exception as exc:
        logger.exception(
            "board_cadence_crontab.task.failed",
            extra={"board_id": str(board_task.board_id), "error": str(exc)},
        )
        raise


def enqueue_board_cadence_crontab(
    board_id: UUID, changed_at: datetime | None = None
) -> bool:
    payload = BoardCadenceCrontabTask(
        board_id=board_id,
        changed_at=changed_at or datetime.now(UTC),
    )
    try:
        task = QueuedTask(
            task_type="board_cadence_crontab",
            payload={
                "board_id": str(payload.board_id),
                "changed_at": payload.changed_at.isoformat(),
            },
            created_at=payload.changed_at,
            attempts=payload.attempts,
        )
        enqueue_task(
            task,
            settings.rq_queue_name,
            redis_url=settings.rq_redis_url,
        )
        logger.info(
            "board_cadence_crontab.queue.enqueued",
            extra={
                "board_id": str(board_id),
                "changed_at": payload.changed_at.isoformat(),
            },
        )
        return True
    except Exception as exc:
        logger.warning(
            "board_cadence_crontab.queue.enqueue_failed",
            extra={"board_id": str(board_id), "error": str(exc)},
        )
        return False


def requeue_if_failed(task: QueuedTask, *, delay_seconds: float = 0) -> bool:
    payload = decode_board_cadence_task(task)
    return _requeue_payload(payload, delay_seconds=delay_seconds)


def _requeue_payload(
    payload: BoardCadenceCrontabTask,
    *,
    delay_seconds: float = 0,
) -> bool:
    try:
        task = QueuedTask(
            task_type="board_cadence_crontab",
            payload={
                "board_id": str(payload.board_id),
                "changed_at": payload.changed_at.isoformat(),
            },
            created_at=payload.changed_at,
            attempts=payload.attempts,
        )
        return generic_requeue_if_failed(
            task,
            settings.rq_queue_name,
            max_retries=settings.rq_dispatch_max_retries,
            redis_url=settings.rq_redis_url,
            delay_seconds=delay_seconds,
        )
    except Exception as exc:
        logger.warning(
            "board_cadence_crontab.requeue.failed",
            extra={"board_id": str(payload.board_id), "error": str(exc)},
        )
        return False
