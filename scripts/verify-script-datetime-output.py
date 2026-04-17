#!/usr/bin/env python3
"""Execute a script and emit evidence that it prints a datetime to stdout."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


DATETIME_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:?\d{2})$"
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8192), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a script and verify that stdout looks like a datetime."
    )
    parser.add_argument(
        "target",
        nargs="?",
        default="scripts/print-current-datetime.sh",
        help="Path to the script to execute.",
    )
    parser.add_argument(
        "--output",
        help="Optional path to write the JSON evidence record.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    target = Path(args.target).resolve()
    if not target.exists():
        print(f"Target does not exist: {target}", file=sys.stderr)
        return 2
    if not target.is_file():
        print(f"Target is not a file: {target}", file=sys.stderr)
        return 2

    completed = subprocess.run(
        [str(target)],
        capture_output=True,
        text=True,
        cwd=str(target.parent.parent),
        check=False,
    )
    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()
    evidence = {
        "executed_at_utc": datetime.now(timezone.utc).isoformat(),
        "target_path": str(target),
        "target_sha256": sha256_file(target),
        "command": [str(target)],
        "exit_code": completed.returncode,
        "stdout": stdout,
        "stderr": stderr,
        "checks": {
            "exit_code_zero": completed.returncode == 0,
            "stdout_present": bool(stdout),
            "stdout_matches_datetime_pattern": bool(DATETIME_RE.fullmatch(stdout)),
        },
    }
    evidence["verified"] = all(evidence["checks"].values())

    payload = json.dumps(evidence, indent=2)
    if args.output:
        output_path = Path(args.output).resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0 if evidence["verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
