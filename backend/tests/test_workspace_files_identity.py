from __future__ import annotations

from pathlib import Path
from uuid import uuid4

import pytest

from app.api import workspace_files as workspace_files_api
from app.api.deps import ActorContext
from app.models.agents import Agent


def _actor_for_board(board_id: str) -> ActorContext:
    return ActorContext(
        actor_type="agent",
        agent=Agent(
            id=uuid4(),
            board_id=workspace_files_api._parse_uuid(board_id),
            gateway_id=uuid4(),
            name="Lead",
            status="online",
        ),
    )


def _write_workspace_file(root: Path, relative_path: str, content: str) -> None:
    target = root / relative_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


@pytest.mark.asyncio
async def test_workspace_file_identity_keeps_duplicate_relative_paths_distinct(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    board_id = str(uuid4())
    worker_one_id = uuid4()
    worker_two_id = uuid4()
    relative_path = "deliverables/review-packet.md"

    worker_one_root = tmp_path / "worker-one"
    worker_two_root = tmp_path / "worker-two"
    _write_workspace_file(worker_one_root, relative_path, "worker-one evidence")
    _write_workspace_file(worker_two_root, relative_path, "worker-two evidence")

    handles = [
        workspace_files_api._WorkspaceHandle(
            agent_id=worker_one_id,
            agent_name="Worker One",
            root_key=f"agent:{worker_one_id}",
            root=worker_one_root,
        ),
        workspace_files_api._WorkspaceHandle(
            agent_id=worker_two_id,
            agent_name="Worker Two",
            root_key=f"agent:{worker_two_id}",
            root=worker_two_root,
        ),
    ]

    async def _fake_workspace_handles(_session: object, _board_id: object):
        return handles

    async def _allow_board_access(_session: object, **_: object) -> None:
        return None

    monkeypatch.setattr(
        workspace_files_api,
        "_workspace_handles_for_board",
        _fake_workspace_handles,
    )
    monkeypatch.setattr(
        workspace_files_api,
        "_require_board_read_access",
        _allow_board_access,
    )

    actor = _actor_for_board(board_id)
    entries = await workspace_files_api.list_workspace_files(
        board_id=board_id,
        agent_id=None,
        task_id=None,
        path="",
        actor=actor,
        session=object(),  # type: ignore[arg-type]
    )

    assert len(entries) == 2
    assert {entry.relative_path for entry in entries} == {relative_path}
    assert {entry.workspace_root_key for entry in entries} == {
        f"agent:{worker_one_id}",
        f"agent:{worker_two_id}",
    }

    worker_one_entry = next(entry for entry in entries if entry.workspace_agent_id == worker_one_id)
    worker_two_entry = next(entry for entry in entries if entry.workspace_agent_id == worker_two_id)

    worker_one_content = await workspace_files_api.get_workspace_file(
        board_id=board_id,
        path=worker_one_entry.path,
        agent_id=None,
        relative_path=worker_one_entry.relative_path,
        workspace_root_key=worker_one_entry.workspace_root_key,
        workspace_agent_id=str(worker_one_entry.workspace_agent_id),
        actor=actor,
        session=object(),  # type: ignore[arg-type]
    )
    worker_two_content = await workspace_files_api.get_workspace_file(
        board_id=board_id,
        path=worker_two_entry.path,
        agent_id=None,
        relative_path=worker_two_entry.relative_path,
        workspace_root_key=worker_two_entry.workspace_root_key,
        workspace_agent_id=str(worker_two_entry.workspace_agent_id),
        actor=actor,
        session=object(),  # type: ignore[arg-type]
    )

    assert worker_one_content.content == "worker-one evidence"
    assert worker_two_content.content == "worker-two evidence"

    download_response = await workspace_files_api.download_workspace_file(
        board_id=board_id,
        path=worker_two_entry.path,
        agent_id=None,
        relative_path=worker_two_entry.relative_path,
        workspace_root_key=worker_two_entry.workspace_root_key,
        workspace_agent_id=str(worker_two_entry.workspace_agent_id),
        actor=actor,
        session=object(),  # type: ignore[arg-type]
    )

    assert download_response.body == b"worker-two evidence"
