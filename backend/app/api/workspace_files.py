"""Workspace file browser API — exposes agent workspace files to authorized users.

Reads from the host filesystem (volume-mounted) using the openclaw.json config
to resolve workspace root paths per agent/board.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api.deps import ACTOR_DEP, SESSION_DEP, ActorContext
from app.models.boards import Board

router = APIRouter(prefix="/boards/{board_id}/workspace", tags=["workspace-files"])

OPENCLAW_CONFIG_PATH = Path(os.environ.get("OPENCLAW_CONFIG_PATH", "/root/.openclaw/openclaw.json"))

# Optional remap: "src_prefix=dst_prefix" e.g. "/root/.openclaw/workspace=/app/workspaces"
# Allows container to access host workspace paths that are mounted at a different location.
_WORKSPACE_REMAP: tuple[str, str] | None = None
_remap_env = os.environ.get("WORKSPACE_ROOT_REMAP", "")
if "=" in _remap_env:
    _src, _dst = _remap_env.split("=", 1)
    _WORKSPACE_REMAP = (_src.rstrip("/"), _dst.rstrip("/"))

_OPENCLAW_CONFIG_FALLBACKS = (
    Path("/etc/openclaw/openclaw.json"),
    Path("/root/.openclaw/openclaw.json"),
)


def _apply_workspace_remap(path: Path) -> Path:
    if _WORKSPACE_REMAP is None:
        return path
    src, dst = _WORKSPACE_REMAP
    s = str(path)
    if s == src or s.startswith(f"{src}/"):
        return Path(dst + s[len(src) :])
    return path


# File extensions we consider safe to read as text
_TEXT_EXTENSIONS = {
    ".md",
    ".txt",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".py",
    ".js",
    ".ts",
    ".tsx",
    ".jsx",
    ".html",
    ".css",
    ".sh",
    ".env",
}

_MAX_FILE_SIZE = 512 * 1024  # 512 KB read limit


class WorkspaceFileEntry(SQLModel):
    name: str
    path: str
    relative_path: str
    workspace_agent_id: UUID | None = None
    workspace_agent_name: str | None = None
    workspace_root_key: str | None = None
    is_dir: bool
    size: int | None = None
    modified_at: str | None = None  # ISO 8601 from file mtime


class WorkspaceFileContent(SQLModel):
    path: str
    content: str
    size: int


@dataclass(frozen=True, slots=True)
class _WorkspaceHandle:
    agent_id: UUID | None
    agent_name: str
    root_key: str
    root: Path


def _openclaw_config_candidates() -> list[Path]:
    candidates: list[Path] = [OPENCLAW_CONFIG_PATH]
    if OPENCLAW_CONFIG_PATH.name == "config.json":
        candidates.append(OPENCLAW_CONFIG_PATH.with_name("openclaw.json"))
    candidates.extend(_OPENCLAW_CONFIG_FALLBACKS)

    seen: set[str] = set()
    ordered: list[Path] = []
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        ordered.append(candidate)
    return ordered


def _load_openclaw_config() -> dict[str, Any]:
    for candidate in _openclaw_config_candidates():
        try:
            if not candidate.exists():
                continue
            with candidate.open() as f:
                return json.load(f)
        except (OSError, PermissionError, json.JSONDecodeError):
            continue
    return {}


def _fallback_workspace_root_for_config_id(config_id: str) -> Path | None:
    candidates: list[Path] = []
    if _WORKSPACE_REMAP is not None:
        _, dst = _WORKSPACE_REMAP
        candidates.append(Path(dst) / f"workspace-{config_id}")
    candidates.extend(
        [
            Path("/app/workspaces") / f"workspace-{config_id}",
            Path("/root/.openclaw/workspace") / f"workspace-{config_id}",
        ]
    )
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        try:
            if candidate.exists():
                return candidate
        except (PermissionError, OSError):
            continue
    return None


def _workspace_root_for_config_id(config_id: str) -> Path | None:
    """Return the workspace Path for an openclaw config agent ID."""
    config = _load_openclaw_config()
    for entry in config.get("agents", {}).get("list", []):
        if entry.get("id") == config_id:
            ws = entry.get("workspace")
            if ws:
                return _apply_workspace_remap(Path(ws))
    return _fallback_workspace_root_for_config_id(config_id)


def _config_id_from_session_id(session_id: str) -> str | None:
    """Extract config ID from session key like 'agent:{config_id}:main'."""
    parts = session_id.split(":")
    if len(parts) >= 2 and parts[0] == "agent":
        return parts[1]
    return None


def _workspace_root_for_agent(agent_id: UUID) -> Path | None:
    """Return workspace Path for an MC agent UUID via openclaw.json."""
    config = _load_openclaw_config()
    str_id = str(agent_id)
    for entry in config.get("agents", {}).get("list", []):
        if str_id in entry.get("id", ""):
            ws = entry.get("workspace")
            if ws:
                return _apply_workspace_remap(Path(ws))
    return _fallback_workspace_root_for_config_id(f"mc-{agent_id}")


def _workspace_root_key_for_agent(agent_id: UUID) -> str:
    return f"agent:{agent_id}"


def _workspace_root_key_for_task_bundle(board_id: UUID, task_id: UUID) -> str:
    return f"task-bundle:{board_id}:{task_id}"


def _lead_workspace_root_for_board(board_id: UUID) -> Path | None:
    root = _workspace_root_for_config_id(f"lead-{board_id}")
    if root is not None:
        return root

    candidates: list[Path] = []
    if _WORKSPACE_REMAP is not None:
        _, dst = _WORKSPACE_REMAP
        candidates.append(Path(dst) / f"workspace-lead-{board_id}")
    candidates.extend(
        [
            Path("/app/workspaces") / f"workspace-lead-{board_id}",
            Path("/root/.openclaw/workspace") / f"workspace-lead-{board_id}",
        ]
    )
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        try:
            if candidate.exists():
                return candidate
        except (PermissionError, OSError):
            continue
    return None


async def _workspace_handles_for_board(
    session: AsyncSession,
    board_id: UUID,
) -> list[_WorkspaceHandle]:
    """Return workspace handles for all agents on a board using their session IDs."""
    from sqlmodel import col, select

    from app.models.agents import Agent as AgentModel

    rows = list(await session.exec(select(AgentModel).where(col(AgentModel.board_id) == board_id)))
    results: list[tuple[str, Path]] = []
    for agent in rows:
        if not agent.openclaw_session_id:
            continue
        config_id = _config_id_from_session_id(agent.openclaw_session_id)
        if not config_id:
            continue
        root = _workspace_root_for_config_id(config_id)
        try:
            if root and root.exists():
                results.append(
                    _WorkspaceHandle(
                        agent_id=agent.id,
                        agent_name=agent.name,
                        root_key=_workspace_root_key_for_agent(agent.id),
                        root=root,
                    )
                )
        except (PermissionError, OSError):
            pass
    return results


def _safe_path(base: Path, rel: str) -> Path | None:
    """Resolve a relative path under base, rejecting traversal attempts."""
    try:
        resolved = (base / rel).resolve()
        if base.resolve() in resolved.parents or resolved == base.resolve():
            return resolved
        return None
    except Exception:
        return None


# Directories considered "output" — only these are surfaced in the UI
_OUTPUT_DIRS = {"deliverables", "output", "artifacts", "reports", "drafts"}

# Root-level system files to always exclude
_SYSTEM_FILES = {
    "AGENTS.md",
    "BOOTSTRAP.md",
    "HEARTBEAT.md",
    "SOUL.md",
    "TOOLS.md",
    "USER.md",
    "IDENTITY.md",
    "WORKFLOW.md",
    "WORKFLOW_AUTO.md",
    "MEMORY.md",
}


def _display_workspace_path(handle: _WorkspaceHandle, relative_path: str) -> str:
    return f"{handle.agent_name}/{relative_path}"


def _list_deliverables(handle: _WorkspaceHandle) -> list[WorkspaceFileEntry]:
    """Return output files with stable origin identity for later reads/downloads."""
    root = handle.root
    entries: list[WorkspaceFileEntry] = []
    for output_dir in _OUTPUT_DIRS:
        target = root / output_dir
        if not target.exists() or not target.is_dir():
            continue
        for item in sorted(target.rglob("*")):
            if any(
                part.startswith(".") or part.startswith("__")
                for part in item.parts[len(root.parts) :]
            ):
                continue
            if item.is_file():
                rel = str(item.relative_to(root))
                stat = item.stat()
                mtime_iso = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
                entries.append(
                    WorkspaceFileEntry(
                        name=item.name,
                        path=_display_workspace_path(handle, rel),
                        relative_path=rel,
                        workspace_agent_id=handle.agent_id,
                        workspace_agent_name=handle.agent_name,
                        workspace_root_key=handle.root_key,
                        is_dir=False,
                        size=stat.st_size,
                        modified_at=mtime_iso,
                    )
                )
    return entries


def _list_task_bundle_files(handle: _WorkspaceHandle) -> list[WorkspaceFileEntry]:
    """Return task-bundle deliverables/evidence files from the lead workspace."""
    root = handle.root
    entries: list[WorkspaceFileEntry] = []
    for output_dir in ("deliverables", "evidence"):
        target = root / output_dir
        if not target.exists() or not target.is_dir():
            continue
        for item in sorted(target.rglob("*")):
            if any(
                part.startswith(".") or part.startswith("__")
                for part in item.parts[len(root.parts) :]
            ):
                continue
            if item.is_file():
                rel = str(item.relative_to(root))
                stat = item.stat()
                mtime_iso = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
                entries.append(
                    WorkspaceFileEntry(
                        name=item.name,
                        path=_display_workspace_path(handle, rel),
                        relative_path=rel,
                        workspace_agent_id=None,
                        workspace_agent_name=handle.agent_name,
                        workspace_root_key=handle.root_key,
                        is_dir=False,
                        size=stat.st_size,
                        modified_at=mtime_iso,
                    )
                )
    return entries


def _task_bundle_handle(board_id: UUID, task_id: UUID) -> _WorkspaceHandle | None:
    lead_root = _lead_workspace_root_for_board(board_id)
    if lead_root is None:
        return None

    task_root = lead_root / "tasks" / str(task_id)
    try:
        if not task_root.exists() or not task_root.is_dir():
            return None
    except (PermissionError, OSError):
        return None

    return _WorkspaceHandle(
        agent_id=None,
        agent_name="Task Bundle",
        root_key=_workspace_root_key_for_task_bundle(board_id, task_id),
        root=task_root,
    )


def _workspace_handle_from_root_key(root_key: str | None) -> _WorkspaceHandle | None:
    if not root_key or not root_key.startswith("task-bundle:"):
        return None
    parts = root_key.split(":")
    if len(parts) != 3:
        return None
    try:
        board_id = UUID(parts[1])
        task_id = UUID(parts[2])
    except ValueError:
        return None
    return _task_bundle_handle(board_id, task_id)


def _relative_path_from_display_path(path: str) -> tuple[str | None, str]:
    parts = path.split("/", 1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return None, path


def _workspace_handle_by_root_key(
    handles: list[_WorkspaceHandle],
    root_key: str | None,
) -> _WorkspaceHandle | None:
    if not root_key:
        return None
    synthetic_handle = _workspace_handle_from_root_key(root_key)
    if synthetic_handle is not None:
        return synthetic_handle
    for handle in handles:
        if handle.root_key == root_key:
            return handle
    return None


def _workspace_handle_by_agent_id(
    handles: list[_WorkspaceHandle],
    agent_id: UUID | None,
) -> _WorkspaceHandle | None:
    if agent_id is None:
        return None
    for handle in handles:
        if handle.agent_id == agent_id:
            return handle
    return None


def _workspace_handle_by_name(
    handles: list[_WorkspaceHandle],
    agent_name: str | None,
) -> _WorkspaceHandle | None:
    if not agent_name:
        return None
    matches = [handle for handle in handles if handle.agent_name == agent_name]
    if len(matches) == 1:
        return matches[0]
    return None


def _resolve_workspace_target(
    *,
    handles: list[_WorkspaceHandle],
    path: str | None,
    relative_path: str | None,
    workspace_root_key: str | None,
    workspace_agent_id: UUID | None,
) -> tuple[_WorkspaceHandle, Path, str]:
    rel_path = relative_path
    agent_name_from_path: str | None = None
    if path:
        agent_name_from_path, parsed_rel_path = _relative_path_from_display_path(path)
        if rel_path is None:
            rel_path = parsed_rel_path
    if rel_path is None or not rel_path.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="relative_path is required.",
        )
    rel_path = rel_path.strip()

    handle = (
        _workspace_handle_by_root_key(handles, workspace_root_key)
        or _workspace_handle_by_agent_id(handles, workspace_agent_id)
        or _workspace_handle_by_name(handles, agent_name_from_path)
    )

    if handle is not None:
        target = _safe_path(handle.root, rel_path)
        if target and target.exists() and target.is_file():
            return handle, target, rel_path
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found.")

    for candidate in handles:
        target = _safe_path(candidate.root, rel_path)
        if target and target.exists() and target.is_file():
            return candidate, target, rel_path

    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found.")


@router.get("/files", response_model=list[WorkspaceFileEntry])
async def list_workspace_files(
    board_id: str,
    agent_id: str | None = Query(default=None, description="Specific agent UUID"),
    task_id: str | None = Query(
        default=None, description="Filter to files mentioned in this task's comments"
    ),
    path: str = Query(default="", description="Sub-directory relative to workspace root"),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> list[WorkspaceFileEntry]:
    """List deliverable files, optionally scoped to a specific task."""
    board_uuid = _parse_uuid(board_id)
    await _require_board_read_access(session, actor=actor, board_id=board_uuid)

    task_bundle_entries: list[WorkspaceFileEntry] = []
    # If task_id provided, limit legacy workspace files to files explicitly mentioned in task comments,
    # and also include the lead task-bundle files directly.
    task_file_paths: set[str] | None = None
    if task_id:
        task_uuid = _parse_uuid(task_id)
        task_file_paths = await _file_paths_from_task(session, task_uuid)
        task_bundle_handle = _task_bundle_handle(board_uuid, task_uuid)
        if task_bundle_handle is not None:
            task_bundle_entries = _list_task_bundle_files(task_bundle_handle)

    if agent_id:
        agent_uuid = _parse_uuid(agent_id)
        handle = _workspace_handle_by_agent_id(
            await _workspace_handles_for_board(session, board_uuid),
            agent_uuid,
        )
        if handle is None:
            return []
        entries = _list_deliverables(handle)
    else:
        # Return deliverables from all agents on this board, namespaced by agent name
        all_entries: list[WorkspaceFileEntry] = []
        seen: set[tuple[str | None, str]] = set()
        for handle in await _workspace_handles_for_board(session, board_uuid):
            for entry in _list_deliverables(handle):
                entry_key = (entry.workspace_root_key, entry.relative_path)
                if entry_key not in seen:
                    seen.add(entry_key)
                    all_entries.append(entry)
        entries = all_entries

    # Filter legacy workspace files by task-mentioned paths if task_id was given.
    if task_file_paths is not None:
        entries = [e for e in entries if e.relative_path in task_file_paths]

    if not task_bundle_entries:
        return entries

    combined: list[WorkspaceFileEntry] = []
    seen: set[tuple[str | None, str]] = set()
    for entry in [*task_bundle_entries, *entries]:
        entry_key = (entry.workspace_root_key, entry.relative_path)
        if entry_key in seen:
            continue
        seen.add(entry_key)
        combined.append(entry)
    return combined


@router.get("/file", response_model=WorkspaceFileContent)
async def get_workspace_file(
    board_id: str,
    path: str | None = Query(default=None, description="Display path from the list endpoint."),
    agent_id: str | None = Query(default=None),
    relative_path: str | None = Query(
        default=None, description="Path relative to the originating workspace root."
    ),
    workspace_root_key: str | None = Query(
        default=None, description="Stable workspace root identity returned by the list endpoint."
    ),
    workspace_agent_id: str | None = Query(
        default=None, description="Stable workspace agent identity returned by the list endpoint."
    ),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> WorkspaceFileContent:
    """Get the content of a workspace file."""
    board_uuid = _parse_uuid(board_id)
    await _require_board_read_access(session, actor=actor, board_id=board_uuid)

    handle, target, rel_path = _resolve_workspace_target(
        handles=await _workspace_handles_for_board(session, board_uuid),
        path=path,
        relative_path=relative_path,
        workspace_root_key=workspace_root_key,
        workspace_agent_id=(
            _parse_uuid(workspace_agent_id)
            if workspace_agent_id
            else _parse_uuid(agent_id) if agent_id else None
        ),
    )
    suffix = target.suffix.lower()
    if suffix not in _TEXT_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail="Binary files are not supported.",
        )
    size = target.stat().st_size
    if size > _MAX_FILE_SIZE:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"File too large ({size} bytes). Max {_MAX_FILE_SIZE} bytes.",
        )
    content = target.read_text(encoding="utf-8", errors="replace")
    display_path = path or _display_workspace_path(handle, rel_path)
    return WorkspaceFileContent(path=display_path, content=content, size=size)


_FILE_PATH_RE = re.compile(
    r"\b(?:deliverables|output|artifacts|reports|drafts)/[\w\-./]+\.\w+",
    re.IGNORECASE,
)


async def _file_paths_from_task(session: AsyncSession, task_id: UUID) -> set[str]:
    """Scan task comments for file paths explicitly mentioned by agents."""
    from sqlmodel import col, select

    from app.models.activity_events import ActivityEvent

    rows = list(
        await session.exec(
            select(ActivityEvent).where(
                col(ActivityEvent.task_id) == task_id,
                col(ActivityEvent.event_type) == "task.comment",
            )
        )
    )
    paths: set[str] = set()
    for row in rows:
        if row.message:
            for match in _FILE_PATH_RE.findall(row.message):
                paths.add(match.strip().rstrip(".,)"))
    return paths


@router.get("/download")
async def download_workspace_file(
    board_id: str,
    path: str | None = Query(
        default=None, description="Display path returned by the list endpoint."
    ),
    agent_id: str | None = Query(default=None),
    relative_path: str | None = Query(
        default=None, description="Path relative to the originating workspace root."
    ),
    workspace_root_key: str | None = Query(
        default=None, description="Stable workspace root identity returned by the list endpoint."
    ),
    workspace_agent_id: str | None = Query(
        default=None, description="Stable workspace agent identity returned by the list endpoint."
    ),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> Response:
    """Download a workspace file as an attachment."""
    from fastapi.responses import Response as FastAPIResponse

    board_uuid = _parse_uuid(board_id)
    await _require_board_read_access(session, actor=actor, board_id=board_uuid)
    _handle, target, rel_path = _resolve_workspace_target(
        handles=await _workspace_handles_for_board(session, board_uuid),
        path=path,
        relative_path=relative_path,
        workspace_root_key=workspace_root_key,
        workspace_agent_id=(
            _parse_uuid(workspace_agent_id)
            if workspace_agent_id
            else _parse_uuid(agent_id) if agent_id else None
        ),
    )
    filename = Path(rel_path).name
    content = target.read_bytes()
    suffix = target.suffix.lower()
    mime = "text/markdown" if suffix == ".md" else "text/plain"
    return FastAPIResponse(
        content=content,
        media_type=mime,
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


def _parse_uuid(value: str) -> UUID:
    try:
        return UUID(value)
    except ValueError:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT)


async def _require_board_read_access(
    session: AsyncSession,
    *,
    actor: ActorContext,
    board_id: UUID,
) -> None:
    from app.services.organizations import require_board_access

    board = await Board.objects.by_id(board_id).first(session)
    if board is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if actor.actor_type == "user" and actor.user is not None:
        await require_board_access(session, user=actor.user, board=board, write=False)
    elif actor.actor_type == "agent" and actor.agent is not None:
        if actor.agent.board_id != board_id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    else:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)


# ---------------------------------------------------------------------------
# Board-group workspace endpoints (group lead agent workspace)
# ---------------------------------------------------------------------------

group_router = APIRouter(prefix="/board-groups/{group_id}/workspace", tags=["workspace-files"])


def _workspace_root_key_for_group_agent(agent_id: UUID) -> str:
    return f"group-agent:{agent_id}"


async def _workspace_handles_for_group(
    session: AsyncSession,
    group_id: UUID,
) -> list[_WorkspaceHandle]:
    """Return workspace paths for the group lead agent.

    Uses the session key to derive config_id (same as _config_id_from_session_id) but
    reads the workspace root directly from the remapped openclaw config without relying
    on the container's /etc/openclaw/config.json (which may be permission-restricted).
    Falls back to deriving the path from the session key pattern when config is unreadable.
    """
    from app.models.agents import Agent as AgentModel
    from app.models.board_groups import BoardGroup

    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None or group.group_agent_id is None:
        return []
    agent = await AgentModel.objects.by_id(group.group_agent_id).first(session)
    if agent is None or not agent.openclaw_session_id:
        return []

    config_id = _config_id_from_session_id(agent.openclaw_session_id)
    if not config_id:
        return []

    # Try reading config (may fail inside container due to permissions)
    root: Path | None = None
    try:
        root = _workspace_root_for_config_id(config_id)
    except (PermissionError, OSError):
        root = None

    # Fallback: derive workspace path from remapped workspace root + config_id convention
    if root is None or not root.exists():
        # Standard convention: workspace-{config_id} under the remapped workspace base
        if _WORKSPACE_REMAP is not None:
            _, dst = _WORKSPACE_REMAP
            candidate = Path(dst) / f"workspace-{config_id}"
            if candidate.exists():
                root = candidate
        # Also try without remap (direct host path)
        if root is None or not root.exists():
            candidate2 = Path("/root/.openclaw/workspace") / f"workspace-{config_id}"
            if candidate2.exists():
                root = candidate2

    if root and root.exists():
        return [
            _WorkspaceHandle(
                agent_id=agent.id,
                agent_name=agent.name,
                root_key=_workspace_root_key_for_group_agent(agent.id),
                root=root,
            )
        ]
    return []


async def _require_group_read_access(
    session: AsyncSession,
    *,
    actor: ActorContext,
    group_id: UUID,
) -> None:
    from sqlalchemy import or_
    from sqlmodel import col, select

    from app.models.board_groups import BoardGroup
    from app.models.organization_board_access import OrganizationBoardAccess
    from app.services.organizations import get_active_membership

    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)

    if actor.actor_type == "agent" and actor.agent is not None:
        # Group agent or board agent within this group is allowed
        if actor.agent.group_id == group_id:
            return
        if actor.agent.board_id is not None:
            from app.models.boards import Board

            board = await Board.objects.by_id(actor.agent.board_id).first(session)
            if board and board.board_group_id == group_id:
                return
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)

    if actor.user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    member = await get_active_membership(session, actor.user)
    if member is None or member.organization_id != group.organization_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)

    if member.all_boards_read or member.all_boards_write:
        return

    access = (
        await session.exec(
            select(OrganizationBoardAccess).where(
                col(OrganizationBoardAccess.organization_member_id) == member.id,
                col(OrganizationBoardAccess.board_group_id) == group_id,
                or_(
                    col(OrganizationBoardAccess.can_read).is_(True),
                    col(OrganizationBoardAccess.can_write).is_(True),
                ),
            )
        )
    ).first()
    if access is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)


@group_router.get("/files", response_model=list[WorkspaceFileEntry])
async def list_group_workspace_files(
    group_id: str,
    task_id: str | None = Query(
        default=None, description="Filter to files mentioned in this task's comments"
    ),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> list[WorkspaceFileEntry]:
    """List deliverable files from the group lead agent workspace."""
    group_uuid = _parse_uuid(group_id)
    await _require_group_read_access(session, actor=actor, group_id=group_uuid)

    task_file_paths: set[str] | None = None
    if task_id:
        task_uuid = _parse_uuid(task_id)
        task_file_paths = await _file_paths_from_task(session, task_uuid)

    all_entries: list[WorkspaceFileEntry] = []
    seen: set[tuple[str | None, str]] = set()
    for handle in await _workspace_handles_for_group(session, group_uuid):
        for entry in _list_deliverables(handle):
            entry_key = (entry.workspace_root_key, entry.relative_path)
            if entry_key not in seen:
                seen.add(entry_key)
                all_entries.append(entry)

    if task_file_paths is not None:
        all_entries = [e for e in all_entries if e.relative_path in task_file_paths]

    return all_entries


@group_router.get("/file", response_model=WorkspaceFileContent)
async def get_group_workspace_file(
    group_id: str,
    path: str | None = Query(
        default=None, description="Display path returned by the list endpoint."
    ),
    relative_path: str | None = Query(
        default=None, description="Path relative to the originating workspace root."
    ),
    workspace_root_key: str | None = Query(
        default=None, description="Stable workspace root identity returned by the list endpoint."
    ),
    workspace_agent_id: str | None = Query(
        default=None, description="Stable workspace agent identity returned by the list endpoint."
    ),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> WorkspaceFileContent:
    """Read a single workspace file from the group lead agent workspace."""
    group_uuid = _parse_uuid(group_id)
    await _require_group_read_access(session, actor=actor, group_id=group_uuid)
    handle, target, rel_path = _resolve_workspace_target(
        handles=await _workspace_handles_for_group(session, group_uuid),
        path=path,
        relative_path=relative_path,
        workspace_root_key=workspace_root_key,
        workspace_agent_id=_parse_uuid(workspace_agent_id) if workspace_agent_id else None,
    )
    suffix = target.suffix.lower()
    if suffix not in _TEXT_EXTENSIONS:
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE)
    return WorkspaceFileContent(
        path=path or _display_workspace_path(handle, rel_path),
        content=target.read_text(errors="replace"),
        size=target.stat().st_size,
    )


@group_router.get("/download")
async def download_group_workspace_file(
    group_id: str,
    path: str | None = Query(
        default=None, description="Display path returned by the list endpoint."
    ),
    relative_path: str | None = Query(
        default=None, description="Path relative to the originating workspace root."
    ),
    workspace_root_key: str | None = Query(
        default=None, description="Stable workspace root identity returned by the list endpoint."
    ),
    workspace_agent_id: str | None = Query(
        default=None, description="Stable workspace agent identity returned by the list endpoint."
    ),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> Response:
    """Download a workspace file from the group lead agent workspace."""
    from fastapi.responses import Response as FastAPIResponse

    group_uuid = _parse_uuid(group_id)
    await _require_group_read_access(session, actor=actor, group_id=group_uuid)
    _handle, target, rel_path = _resolve_workspace_target(
        handles=await _workspace_handles_for_group(session, group_uuid),
        path=path,
        relative_path=relative_path,
        workspace_root_key=workspace_root_key,
        workspace_agent_id=_parse_uuid(workspace_agent_id) if workspace_agent_id else None,
    )
    filename = Path(rel_path).name
    content = target.read_bytes()
    suffix = target.suffix.lower()
    mime = "text/markdown" if suffix == ".md" else "text/plain"
    return FastAPIResponse(
        content=content,
        media_type=mime,
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
