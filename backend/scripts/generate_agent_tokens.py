"""Regenerate `.tokens` from live agents using the stable token derivation."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import sys
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen

BACKEND_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(BACKEND_ROOT))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Regenerate .tokens from live agents.")
    parser.add_argument(
        "--env-path",
        default=str(REPO_ROOT / "backend" / ".env"),
        help="Path to backend .env file",
    )
    parser.add_argument(
        "--output",
        default=str(REPO_ROOT / ".tokens"),
        help="Output JSON file path for the regenerated token snapshot",
    )
    parser.add_argument(
        "--base-url",
        default="http://localhost:8002",
        help="Mission Control base URL",
    )
    parser.add_argument(
        "--agents-path",
        default="/api/v1/agents",
        help="API path for the agent list",
    )
    parser.add_argument(
        "--board-id",
        default=None,
        help="Optional board id filter",
    )
    return parser.parse_args()


def _read_dotenv_value(path: Path, key: str) -> str:
    if not path.exists():
        raise FileNotFoundError(f"Dotenv file not found: {path}")
    prefix = f"{key}="
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line.startswith(prefix):
            return line.split("=", 1)[1].strip()
    raise KeyError(f"Missing required key {key!r} in {path}")


def _stable_agent_token(agent_id: str, local_auth_token: str) -> str:
    message = f"mission-control-agent-token:v1:{agent_id}".encode("utf-8")
    digest = hmac.new(
        local_auth_token.strip().encode("utf-8"),
        message,
        hashlib.sha256,
    ).digest()
    token = base64.urlsafe_b64encode(digest).decode("utf-8").rstrip("=")
    return f"mca_{token}"


def _fetch_agents(base_url: str, agents_path: str, local_auth_token: str) -> list[dict[str, Any]]:
    req = Request(
        f"{base_url}{agents_path}",
        headers={"Authorization": f"Bearer {local_auth_token}", "Accept": "application/json"},
        method="GET",
    )
    with urlopen(req) as response:
        payload = json.loads(response.read().decode("utf-8"))

    if isinstance(payload, list):
        return [entry for entry in payload if isinstance(entry, dict)]

    for key in ("agents", "items", "data", "results"):
        value = payload.get(key)
        if isinstance(value, list):
            return [entry for entry in value if isinstance(entry, dict)]

    raise ValueError("Unrecognized agent list response shape.")


def main() -> int:
    args = _parse_args()
    env_path = Path(args.env_path).resolve()
    output_path = Path(args.output).resolve()

    local_auth_token = _read_dotenv_value(env_path, "LOCAL_AUTH_TOKEN")
    agents = _fetch_agents(args.base_url, args.agents_path, local_auth_token)

    if args.board_id:
        agents = [agent for agent in agents if str(agent.get("board_id") or "") == args.board_id]

    token_rows: list[dict[str, Any]] = []
    for agent in agents:
        agent_id = str(agent.get("id") or agent.get("agent_id") or "")
        if not agent_id:
            continue
        token_rows.append(
            {
                **agent,
                "token": _stable_agent_token(agent_id, local_auth_token),
            }
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(token_rows, indent=2, sort_keys=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
