"""Helpers for rendering cron commands through the local API gate."""

from __future__ import annotations

import os
import shlex

CRON_GATE_RUNNER = os.getenv(
    "MC_CRON_GATE_RUNNER",
    "/home/cronjev/mission-control-tfsmrt/scripts/cron/mission-control-cron-runner.sh",
)


def render_gated_cron_command(
    *,
    workdir: str,
    command: str,
    log_dir: str,
    log_file: str,
) -> str:
    """Render a cron command guarded by the local Mission Control cron gate."""
    shell_command = f"cd {shlex.quote(workdir)} && {command}"
    return (
        f"mkdir -p {shlex.quote(log_dir)} && {shlex.quote(CRON_GATE_RUNNER)} "
        f"-- bash -lc {shlex.quote(shell_command)} >> {log_file} 2>&1"
    )
