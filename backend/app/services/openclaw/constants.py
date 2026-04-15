"""Shared constants for lifecycle orchestration services."""

from __future__ import annotations

import random
import re
from datetime import timedelta
from typing import Any

_GATEWAY_OPENCLAW_AGENT_PREFIX = "mc-gateway-"
_GATEWAY_AGENT_PREFIX = f"agent:{_GATEWAY_OPENCLAW_AGENT_PREFIX}"
_GATEWAY_AGENT_SUFFIX = ":main"

DEFAULT_HEARTBEAT_CONFIG: dict[str, Any] = {
    "every": "10m",
    "target": "last",
    "includeReasoning": False,
}

OFFLINE_AFTER = timedelta(minutes=10)
# Provisioning convergence policy:
# - require first heartbeat/check-in within 30s of wake
# - allow up to 3 wake attempts before giving up
CHECKIN_DEADLINE_AFTER_WAKE = timedelta(seconds=30)
MAX_WAKE_ATTEMPTS_WITHOUT_CHECKIN = 3
AGENT_SESSION_PREFIX = "agent"

DEFAULT_CHANNEL_HEARTBEAT_VISIBILITY: dict[str, bool] = {
    # Suppress routine HEARTBEAT_OK delivery by default.
    "showOk": False,
    "showAlerts": True,
    "useIndicator": True,
}

DEFAULT_IDENTITY_PROFILE = {
    "role": "Generalist",
    "communication_style": "direct, concise, practical",
    "emoji": ":gear:",
}

IDENTITY_PROFILE_FIELDS = {
    "role": "identity_role",
    "communication_style": "identity_communication_style",
    "emoji": "identity_emoji",
}

EXTRA_IDENTITY_PROFILE_FIELDS = {
    "autonomy_level": "identity_autonomy_level",
    "verbosity": "identity_verbosity",
    "output_format": "identity_output_format",
    "update_cadence": "identity_update_cadence",
    # Per-agent charter (optional).
    # Used to give agents a "purpose in life" and a distinct vibe.
    "purpose": "identity_purpose",
    "personality": "identity_personality",
    "custom_instructions": "identity_custom_instructions",
}

DEFAULT_GATEWAY_FILES = frozenset(
    {
        "AGENTS.md",
        "SOUL.md",
        "TOOLS.md",
        "IDENTITY.md",
        "USER.md",
        "HEARTBEAT.md",
        "MEMORY.md",
    },
)

MANAGED_CORE_FILES = frozenset(
    {
        "AGENTS.md",
        "TOOLS.md",
    },
)

BOARD_WORKER_GATEWAY_FILES = frozenset(
    {
        "AGENTS.md",
        "SOUL.md",
        "TOOLS.md",
        "IDENTITY.md",
        "USER.md",
        "HEARTBEAT.md",
        "MEMORY.md",
    },
)

BOARD_LEAD_GATEWAY_FILES = frozenset(
    {
        "AGENTS.md",
        "BOOTSTRAP.md",
        "IDENTITY.md",
        "SOUL.md",
        "USER.md",
        "MEMORY.md",
        "TOOLS.md",
        "HEARTBEAT.md",
    },
)

GROUP_LEAD_GATEWAY_FILES = frozenset(
    {
        "AGENTS.md",
        "BOOTSTRAP.md",
        "IDENTITY.md",
        "SOUL.md",
        "USER.md",
        "MEMORY.md",
        "TOOLS.md",
        "HEARTBEAT.md",
    },
)

# These files are intended to evolve within the agent workspace.
# Provision them if missing, but avoid overwriting existing content during updates.
#
# Examples:
# - USER.md: human-provided context + lead intake notes
# - MEMORY.md: curated long-term memory (consolidated)
# - HEARTBEAT.md: runtime behavior can evolve locally and must survive reprovisioning.
PRESERVE_AGENT_EDITABLE_FILES = frozenset(
    {
        "HEARTBEAT.md",
        "USER.md",
        "MEMORY.md",
    }
)

HEARTBEAT_LEAD_TEMPLATE = "BOARD_HEARTBEAT.md.j2"
HEARTBEAT_AGENT_TEMPLATE = "BOARD_HEARTBEAT.md.j2"
SESSION_KEY_PARTS_MIN = 2
_SESSION_KEY_PARTS_MIN = SESSION_KEY_PARTS_MIN

GATEWAY_MAIN_TEMPLATE_MAP = {
    "AGENTS.md": "GATEWAY_MAIN_AGENTS.md.j2",
}

# Temporary gateway-main contract: only render files that have dedicated gateway-main
# templates. The generic DEFAULT_GATEWAY_FILES contract falls back to unresolved
# template names (for example TOOLS.md / IDENTITY.md) and board heartbeat behavior.
# Expand this only after the remaining gateway-main template family is implemented.
GATEWAY_MAIN_FILES = frozenset(
    {
        "AGENTS.md",
    },
)

BOARD_WORKER_TEMPLATE_MAP = {
    "AGENTS.md": "BOARD_WORKER_AGENTS.md.j2",
    "IDENTITY.md": "BOARD_IDENTITY.md.j2",
    "SOUL.md": "BOARD_SOUL.md.j2",
    "MEMORY.md": "BOARD_MEMORY.md.j2",
    "HEARTBEAT.md": "BOARD_HEARTBEAT.md.j2",
    "GATED-HEARTBEAT.md": "BOARD_WORKER_GATED-HEARTBEAT.md.j2",
    "USER.md": "BOARD_USER.md.j2",
    "TOOLS.md": "BOARD_WORKER_TOOLS.md.j2",
}

BOARD_LEAD_TEMPLATE_MAP = {
    "AGENTS.md": "BOARD_LEAD_AGENTS.md.j2",
    "BOOTSTRAP.md": "BOARD_BOOTSTRAP.md.j2",
    "IDENTITY.md": "BOARD_IDENTITY.md.j2",
    "SOUL.md": "BOARD_SOUL.md.j2",
    "MEMORY.md": "BOARD_MEMORY.md.j2",
    "HEARTBEAT.md": "BOARD_HEARTBEAT.md.j2",
    "GATED-HEARTBEAT.md": "BOARD_LEAD_GATED-HEARTBEAT.md.j2",
    "USER.md": "BOARD_USER.md.j2",
    "TOOLS.md": "BOARD_LEAD_TOOLS.md.j2",
}

_TOOLS_KV_RE = re.compile(r"^(?P<key>[A-Z0-9_]+)=(?P<value>.*)$")
_NON_TRANSIENT_GATEWAY_ERROR_MARKERS = ("unsupported file",)
_TRANSIENT_GATEWAY_ERROR_MARKERS = (
    "connect call failed",
    "connection refused",
    "errno 111",
    "econnrefused",
    "did not receive a valid http response",
    "no route to host",
    "network is unreachable",
    "host is down",
    "name or service not known",
    "received 1012",
    "service restart",
    "http 503",
    "http 502",
    "http 504",
    "temporar",
    "timeout",
    "timed out",
    "connection closed",
    "connection reset",
)

_COORDINATION_GATEWAY_TIMEOUT_S = 45.0
_COORDINATION_GATEWAY_BASE_DELAY_S = 0.5
_COORDINATION_GATEWAY_MAX_DELAY_S = 5.0
_SECURE_RANDOM = random.SystemRandom()
