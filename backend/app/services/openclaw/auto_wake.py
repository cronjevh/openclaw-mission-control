"""Central toggle for automatic OpenClaw wake/reprovision and message dispatch behavior.

When disabled (default), this blocks:
  - All chat.send gateway RPC calls (send_message in gateway_rpc.py)
  - Automatic offline agent re-provisioning (wake_agent_if_offline in gateway_dispatch.py)
  - Watchdog background loop (agent_watchdog.py)
  - Lifecycle reconciliation queue (lifecycle_reconcile.py)

Board dispatch logic should be handled by external scripting (e.g. mc-board-dispatch.ps1)
which can make deterministic decisions without LLM invocation overhead.
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
