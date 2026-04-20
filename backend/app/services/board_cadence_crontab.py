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
from app.models.agents import Agent
from app.models.boards import Board
from sqlalchemy import select
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


@dataclass(frozen=True)
class BoardCadenceCrontabTask:
    """Payload for regenerating crontab entries after board cadence change."""

    board_id: UUID
    changed_at: datetime
    attempts: int = 0


def decode_board_cadence_task(task: QueuedTask) -> BoardCadenceCrontabTask:
    """Decode a queued task envelope into a BoardCadenceCrontabTask."""
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
    """Return the crontab schedule string for a given cadence."""
    return f"*/{cadence_minutes} * * * *"


def _build_crontab_line(
    worker_id: str,
    cadence_minutes: int,
    board_id: str | None = None,
    is_lead: bool = False,
) -> str:
    """Build a single crontab entry line using mcon workflow dispatch."""
    schedule = _format_crontab_schedule(cadence_minutes)
    if is_lead and board_id:
        workspace_dir = f"{WORKSPACE_BASE_DIR}/workspace-lead-{board_id}"
    else:
        workspace_dir = f"{WORKSPACE_BASE_DIR}/workspace-mc-{worker_id}"
    return f"{schedule} {CRON_USER} cd {workspace_dir} && {MCON_PATH} workflow dispatch"


def _build_crontab_content(
    board: Board, workers: list[Agent], cadence_minutes: int
) -> str:
    """Generate the full crontab file content."""
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

    for worker in workers:
        line = _build_crontab_line(
            str(worker.id),
            cadence_minutes,
            board_id=str(board.id),
            is_lead=getattr(worker, "is_board_lead", False),
        )
        lines.append(line)

    lines.append("")
    return "\n".join(lines)


def _crontab_file_path(board_id: str) -> Path:
    """Return the path to the board-specific crontab file."""
    # Use short board ID (first 8 chars) for filename brevity
    short_id = board_id[:8]
    filename = f"{CRONTAB_PREFIX}{short_id}"
    return Path(CRONTAB_DIR) / filename


async def _fetch_board_workers(session: AsyncSession, board_id: UUID) -> list[Agent]:
    """Fetch all non-lead worker records for a board."""
    stmt = select(Agent).where(Agent.board_id == board_id)
    result = await session.exec(stmt)
    agents = list(result.scalars().all())
    logger.info(
        "board_cadence_crontab.workers_fetched",
        extra={
            "board_id": str(board_id),
            "count": len(agents),
            "types": [type(a).__name__ for a in agents],
        },
    )
    return agents


def validate_cadence(cadence: Any) -> tuple[bool, str]:
    """Validate cadence value. Returns (is_valid, error_message)."""
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
    """Generate crontab entries for a board's workers.

    Args:
        session: DB session
        board_id: Board UUID
        dry_run: If True, return content without writing file
        crontab_dir: Override default crontab directory

    Returns:
        (crontab_content, file_path) — file_path is None if dry_run
    """
    # Fetch board
    board = await crud.get_by_id(session, Board, board_id)
    if board is None:
        raise ValueError(f"Board not found: {board_id}")

    cadence = getattr(board, "cadence_minutes", None)

    # Validate cadence
    if cadence is not None:
        valid, err = validate_cadence(cadence)
        if not valid:
            raise ValueError(f"Invalid cadence for board {board_id}: {err}")

    # Fetch workers
    workers = await _fetch_board_workers(session, board_id)

    # Build content
    content = _build_crontab_content(
        board, workers, cadence if cadence is not None else 0
    )

    if dry_run:
        logger.info(
            "board_cadence_crontab.generated.dry_run",
            extra={
                "board_id": str(board_id),
                "cadence": cadence,
                "workers": len(workers),
            },
        )
        return content, None

    # Determine file path
    output_dir = crontab_dir or CRONTAB_DIR
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    file_path = _crontab_file_path(str(board_id))

    # Write file
    file_path.write_text(content, encoding="utf-8")

    # Set permissions: 644, owned by root
    os.chmod(file_path, 0o644)

    logger.info(
        "board_cadence_crontab.generated",
        extra={
            "board_id": str(board_id),
            "file": str(file_path),
            "cadence": cadence,
            "workers": len(workers),
        },
    )
    return content, file_path


async def process_board_cadence_crontab_task(task: QueuedTask) -> None:
    """Queue worker handler: regenerate crontab for a board after cadence change."""
    board_task = decode_board_cadence_task(task)
    logger.info(
        "board_cadence_crontab.task.start",
        extra={
            "board_id": str(board_task.board_id),
            "changed_at": board_task.changed_at.isoformat(),
        },
    )
    try:
        # Get DB session
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
    """Enqueue a board cadence crontab regeneration task.

    Called from the board update handler when cadence_minutes changes.
    """
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
    """Worker-facing requeue wrapper: decode task then requeue with retries."""
    payload = decode_board_cadence_task(task)
    return _requeue_payload(payload, delay_seconds=delay_seconds)


def _requeue_payload(
    payload: BoardCadenceCrontabTask,
    *,
    delay_seconds: float = 0,
) -> bool:
    """Internal: requeue a decoded payload with capped retries."""
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
