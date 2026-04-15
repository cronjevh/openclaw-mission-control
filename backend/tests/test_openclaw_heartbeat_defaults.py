from __future__ import annotations

from uuid import uuid4

from app.models.agents import Agent
from app.services.openclaw.constants import DEFAULT_HEARTBEAT_CONFIG
from app.services.openclaw.constants import MANAGED_CORE_FILES
from app.services.openclaw.constants import PRESERVE_AGENT_EDITABLE_FILES
from app.services.openclaw.db_agent_state import ensure_heartbeat_config


def test_default_heartbeat_config_matches_operational_cadence() -> None:
    assert DEFAULT_HEARTBEAT_CONFIG == {
        "every": "10m",
        "target": "last",
        "includeReasoning": False,
    }


def test_ensure_heartbeat_config_uses_operational_default() -> None:
    agent = Agent(
        id=uuid4(),
        board_id=uuid4(),
        gateway_id=uuid4(),
        name="agent",
        status="offline",
        heartbeat_config=None,
    )

    ensure_heartbeat_config(agent)

    assert agent.heartbeat_config == DEFAULT_HEARTBEAT_CONFIG


def test_preserve_editable_files_covers_curated_board_runtime_files() -> None:
    assert PRESERVE_AGENT_EDITABLE_FILES == {
        "HEARTBEAT.md",
        "USER.md",
        "MEMORY.md",
    }


def test_managed_core_files_cover_authoritative_sync_pair() -> None:
    assert MANAGED_CORE_FILES == {
        "AGENTS.md",
        "TOOLS.md",
    }
