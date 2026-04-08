"""Central toggle for automatic OpenClaw wake/reprovision behavior.

This is intentionally separate from the core lifecycle code so operators have a
single place to understand the temporary kill switch while debugging wake
thrash. Explicit operator-triggered provisioning/update flows still work; this
toggle only guards background or implicit "make it wake somehow" paths.
"""

from __future__ import annotations

from app.core.config import settings

AUTO_WAKE_KILL_SWITCH_ENV = "OPENCLAW_AUTOMATIC_WAKE_REPROVISION_ENABLED"


def automatic_wake_reprovision_enabled() -> bool:
    """Return whether background/implicit wake recovery is enabled."""
    return settings.openclaw_automatic_wake_reprovision_enabled


def automatic_wake_reprovision_disabled_reason() -> str:
    """Human-readable note for logs/docs when the kill switch is active."""
    return (
        "automatic OpenClaw wake/reprovision is disabled "
        f"(set {AUTO_WAKE_KILL_SWITCH_ENV}=true to re-enable)"
    )
