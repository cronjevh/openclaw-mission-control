"""Workspace file browser API — exposes agent workspace files to authorized users.

Reads from the host filesystem (volume-mounted) using the openclaw.json config
to resolve workspace root paths per agent/board.
"""

from __future__ import annotations

import json
import re
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Response, status
from sqlmodel import SQLModel

from app.api.deps import ACTOR_DEP, SESSION_DEP, ActorContext
from app.models.boards import Board
from fastapi import Depends
from sqlmodel.ext.asyncio.session import AsyncSession

router = APIRouter(prefix="/boards/{board_id}/workspace", tags=["workspace-files"])

OPENCLAW_CONFIG_PATH = Path(
    os.environ.get("OPENCLAW_CONFIG_PATH", "/root/.openclaw/openclaw.json")
)

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
        return Path(dst + s[len(src):])
    return path

# File extensions we consider safe to read as text
_TEXT_EXTENSIONS = {
    ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".py", ".js",
    ".ts", ".tsx", ".jsx", ".html", ".css", ".sh", ".env",
}

_MAX_FILE_SIZE = 512 * 1024  # 512 KB read limit


class WorkspaceFileEntry(SQLModel):
    name: str
    path: str  # relative to workspace root
    is_dir: bool
    size: int | None = None
    modified_at: str | None = None  # ISO 8601 from file mtime


class WorkspaceFileContent(SQLModel):
    path: str
    content: str
    size: int


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


async def _workspace_roots_for_board(
    session: AsyncSession,
    board_id: UUID,
) -> list[tuple[str, Path]]:
    """Return workspace paths for all agents on a board using their session IDs."""
    from sqlmodel import select, col
    from app.models.agents import Agent as AgentModel

    rows = list(
        await session.exec(
            select(AgentModel).where(col(AgentModel.board_id) == board_id)
        )
    )
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
                results.append((agent.name, root))
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
    "AGENTS.md", "BOOTSTRAP.md", "HEARTBEAT.md", "SOUL.md",
    "TOOLS.md", "USER.md", "IDENTITY.md", "WORKFLOW.md",
    "WORKFLOW_AUTO.md", "MEMORY.md",
}


def _list_deliverables(root: Path, agent_name: str) -> list[WorkspaceFileEntry]:
    """Return only output/deliverable files, prefixed with agent name to avoid collisions."""
    entries = []
    for output_dir in _OUTPUT_DIRS:
        target = root / output_dir
        if not target.exists() or not target.is_dir():
            continue
        for item in sorted(target.rglob("*")):
            if any(
                part.startswith(".") or part.startswith("__")
                for part in item.parts[len(root.parts):]
            ):
                continue
            if item.is_file():
                rel = str(item.relative_to(root))
                stat = item.stat()
                mtime_iso = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
                entries.append(
                    WorkspaceFileEntry(
                        name=item.name,
                        path=f"{agent_name}/{rel}",
                        is_dir=False,
                        size=stat.st_size,
                        modified_at=mtime_iso,
                    )
                )
    return entries


@router.get("/files", response_model=list[WorkspaceFileEntry])
async def list_workspace_files(
    board_id: str,
    agent_id: str | None = Query(default=None, description="Specific agent UUID"),
    task_id: str | None = Query(default=None, description="Filter to files mentioned in this task's comments"),
    path: str = Query(default="", description="Sub-directory relative to workspace root"),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> list[WorkspaceFileEntry]:
    """List deliverable files, optionally scoped to a specific task."""
    board_uuid = _parse_uuid(board_id)
    await _require_board_read_access(session, actor=actor, board_id=board_uuid)

    # If task_id provided, limit to files explicitly mentioned in task comments
    task_file_paths: set[str] | None = None
    if task_id:
        task_uuid = _parse_uuid(task_id)
        task_file_paths = await _file_paths_from_task(session, task_uuid)

    if agent_id:
        agent_uuid = _parse_uuid(agent_id)
        root = _workspace_root_for_agent(agent_uuid)
        if not root or not root.exists():
            return []
        entries = _list_deliverables(root, "agent")
    else:
        # Return deliverables from all agents on this board, namespaced by agent name
        all_entries: list[WorkspaceFileEntry] = []
        seen: set[str] = set()
        for name, root in await _workspace_roots_for_board(session, board_uuid):
            for entry in _list_deliverables(root, name):
                if entry.path not in seen:
                    seen.add(entry.path)
                    all_entries.append(entry)
        entries = all_entries

    # Filter by task-mentioned paths if task_id was given
    if task_file_paths is not None:
        entries = [
            e for e in entries
            if any(tp in e.path for tp in task_file_paths)
        ]

    return entries


@router.get("/file", response_model=WorkspaceFileContent)
async def get_workspace_file(
    board_id: str,
    path: str = Query(..., description="File path relative to workspace root"),
    agent_id: str | None = Query(default=None),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> WorkspaceFileContent:
    """Get the content of a workspace file."""
    board_uuid = _parse_uuid(board_id)
    await _require_board_read_access(session, actor=actor, board_id=board_uuid)

    # path format from list endpoint: "{agent_name}/{rel_path}" e.g. "Copywriter 1/deliverables/foo.md"
    # Strip the leading agent_name segment to get the actual relative path
    parts = path.split("/", 1)
    rel_path = parts[1] if len(parts) == 2 else path

    agent_roots: list[tuple[str, Path]] = []
    if agent_id:
        r = _workspace_root_for_agent(_parse_uuid(agent_id))
        if r:
            agent_roots = [("agent", r)]
    else:
        agent_roots = await _workspace_roots_for_board(session, board_uuid)

    for _name, root in agent_roots:
        target = _safe_path(root, rel_path)
        if target and target.exists() and target.is_file():
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
            return WorkspaceFileContent(path=path, content=content, size=size)

    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found.")


_FILE_PATH_RE = re.compile(
    r'\b(?:deliverables|output|artifacts|reports|drafts)/[\w\-./]+\.\w+',
    re.IGNORECASE,
)


async def _file_paths_from_task(session: AsyncSession, task_id: UUID) -> set[str]:
    """Scan task comments for file paths explicitly mentioned by agents."""
    from sqlmodel import select, col
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
    path: str = Query(..., description="File path (agent_name/relative/path)"),
    agent_id: str | None = Query(default=None),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> Response:
    """Download a workspace file as an attachment."""
    from fastapi.responses import Response as FastAPIResponse

    board_uuid = _parse_uuid(board_id)
    await _require_board_read_access(session, actor=actor, board_id=board_uuid)

    parts = path.split("/", 1)
    rel_path = parts[1] if len(parts) == 2 else path
    filename = Path(rel_path).name

    agent_roots: list[tuple[str, Path]] = []
    if agent_id:
        r = _workspace_root_for_agent(_parse_uuid(agent_id))
        if r:
            agent_roots = [("agent", r)]
    else:
        agent_roots = await _workspace_roots_for_board(session, board_uuid)

    for _name, root in agent_roots:
        target = _safe_path(root, rel_path)
        if target and target.exists() and target.is_file():
            content = target.read_bytes()
            suffix = target.suffix.lower()
            mime = "text/markdown" if suffix == ".md" else "text/plain"
            return FastAPIResponse(
                content=content,
                media_type=mime,
                headers={"Content-Disposition": f'attachment; filename="{filename}"'},
            )

    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found.")


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


async def _workspace_roots_for_group(
    session: AsyncSession,
    group_id: UUID,
) -> list[tuple[str, Path]]:
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
        return [(agent.name, root)]
    return []


async def _require_group_read_access(
    session: AsyncSession,
    *,
    actor: ActorContext,
    group_id: UUID,
) -> None:
    from app.models.board_groups import BoardGroup
    from app.services.organizations import get_active_membership
    from sqlalchemy import or_
    from sqlmodel import select, col
    from app.models.organization_board_access import OrganizationBoardAccess

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

    access = (await session.exec(
        select(OrganizationBoardAccess).where(
            col(OrganizationBoardAccess.organization_member_id) == member.id,
            col(OrganizationBoardAccess.board_group_id) == group_id,
            or_(
                col(OrganizationBoardAccess.can_read).is_(True),
                col(OrganizationBoardAccess.can_write).is_(True),
            ),
        )
    )).first()
    if access is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)


@group_router.get("/files", response_model=list[WorkspaceFileEntry])
async def list_group_workspace_files(
    group_id: str,
    task_id: str | None = Query(default=None, description="Filter to files mentioned in this task's comments"),
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
    seen: set[str] = set()
    for name, root in await _workspace_roots_for_group(session, group_uuid):
        for entry in _list_deliverables(root, name):
            if entry.path not in seen:
                seen.add(entry.path)
                all_entries.append(entry)

    if task_file_paths is not None:
        all_entries = [
            e for e in all_entries
            if any(tp in e.path for tp in task_file_paths)
        ]

    return all_entries


@group_router.get("/file", response_model=WorkspaceFileContent)
async def get_group_workspace_file(
    group_id: str,
    path: str = Query(..., description="File path (agent_name/relative/path)"),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> WorkspaceFileContent:
    """Read a single workspace file from the group lead agent workspace."""
    group_uuid = _parse_uuid(group_id)
    await _require_group_read_access(session, actor=actor, group_id=group_uuid)

    parts = path.split("/", 1)
    rel_path = parts[1] if len(parts) == 2 else path

    for _name, root in await _workspace_roots_for_group(session, group_uuid):
        target = _safe_path(root, rel_path)
        if target and target.exists() and target.is_file():
            suffix = target.suffix.lower()
            if suffix not in _TEXT_EXTENSIONS:
                raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE)
            return WorkspaceFileContent(path=path, content=target.read_text(errors="replace"), size=target.stat().st_size)

    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found.")


@group_router.get("/download")
async def download_group_workspace_file(
    group_id: str,
    path: str = Query(..., description="File path (agent_name/relative/path)"),
    actor: ActorContext = ACTOR_DEP,
    session: AsyncSession = SESSION_DEP,
) -> Response:
    """Download a workspace file from the group lead agent workspace."""
    from fastapi.responses import Response as FastAPIResponse

    group_uuid = _parse_uuid(group_id)
    await _require_group_read_access(session, actor=actor, group_id=group_uuid)

    parts = path.split("/", 1)
    rel_path = parts[1] if len(parts) == 2 else path
    filename = Path(rel_path).name

    for _name, root in await _workspace_roots_for_group(session, group_uuid):
        target = _safe_path(root, rel_path)
        if target and target.exists() and target.is_file():
            content = target.read_bytes()
            suffix = target.suffix.lower()
            mime = "text/markdown" if suffix == ".md" else "text/plain"
            return FastAPIResponse(
                content=content,
                media_type=mime,
                headers={"Content-Disposition": f'attachment; filename="{filename}"'},
            )

    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found.")
