from __future__ import annotations

import json
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api import workspace_files
from app.models.agents import Agent
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.organizations import Organization


async def _make_engine() -> AsyncEngine:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn, conn.begin():
        await conn.run_sync(SQLModel.metadata.create_all)
    return engine


async def _make_session(engine: AsyncEngine) -> AsyncSession:
    return AsyncSession(engine, expire_on_commit=False)


def test_load_openclaw_config_falls_back_when_primary_candidate_is_unreadable(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    good_path = tmp_path / "openclaw.json"
    expected = {
        "agents": {
            "list": [
                {
                    "id": "mc-test",
                    "workspace": "/tmp/workspace-mc-test",
                }
            ]
        }
    }
    good_path.write_text(json.dumps(expected), encoding="utf-8")

    class _BlockedPath:
        def exists(self) -> bool:
            raise PermissionError("blocked")

    monkeypatch.setattr(
        workspace_files,
        "_openclaw_config_candidates",
        lambda: [_BlockedPath(), good_path],
    )

    assert workspace_files._load_openclaw_config() == expected


def test_apply_workspace_remap_requires_path_boundary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        workspace_files,
        "_WORKSPACE_REMAP",
        ("/home/cronjev/.openclaw/workspace", "/app/workspaces"),
    )

    remapped = workspace_files._apply_workspace_remap(
        Path("/home/cronjev/.openclaw/workspace/project-a"),
    )
    untouched = workspace_files._apply_workspace_remap(
        Path("/home/cronjev/.openclaw/workspace-mc-123"),
    )

    assert remapped == Path("/app/workspaces/project-a")
    assert untouched == Path("/home/cronjev/.openclaw/workspace-mc-123")


@pytest.mark.asyncio
async def test_workspace_roots_for_board_falls_back_to_remapped_workspace_when_config_unreadable(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            org_id = uuid4()
            gateway_id = uuid4()
            board_id = uuid4()
            agent_id = uuid4()

            session.add(Organization(id=org_id, name="org"))
            session.add(
                Gateway(
                    id=gateway_id,
                    organization_id=org_id,
                    name="gateway",
                    url="https://gateway.local",
                    workspace_root="/tmp/workspace",
                ),
            )
            session.add(
                Board(
                    id=board_id,
                    organization_id=org_id,
                    gateway_id=gateway_id,
                    name="board",
                    slug="board",
                ),
            )
            session.add(
                Agent(
                    id=agent_id,
                    board_id=board_id,
                    gateway_id=gateway_id,
                    name="Worker",
                    status="online",
                    openclaw_session_id=f"agent:mc-{agent_id}:main",
                ),
            )
            await session.commit()

            workspace_root = tmp_path / f"workspace-mc-{agent_id}"
            (workspace_root / "deliverables").mkdir(parents=True)
            (workspace_root / "deliverables" / "report.md").write_text(
                "hello",
                encoding="utf-8",
            )

            monkeypatch.setattr(workspace_files, "_load_openclaw_config", lambda: {})
            monkeypatch.setattr(
                workspace_files,
                "_WORKSPACE_REMAP",
                ("/home/cronjev/.openclaw/workspace", str(tmp_path)),
            )

            roots = await workspace_files._workspace_roots_for_board(session, board_id)

            assert roots == [("Worker", workspace_root)]
    finally:
        await engine.dispose()
