#!/usr/bin/env python3

import os
import json
import requests
import re
from pathlib import Path
from typing import Dict, List, Optional, Any

OUTPUT_ROOT = Path("/home/cronjev/mission-control-tfsmrt/workspaces")
API_BASE_URL = "http://localhost:8002"
UI_BASE_URL = "http://localhost:3000"
OPENCLAW_JSON = Path("/home/cronjev/.openclaw/openclaw.json")
ENV_FILE = Path("/home/cronjev/mission-control-tfsmrt/backend/.env")

def get_local_auth_token() -> str:
    if not ENV_FILE.exists():
        raise FileNotFoundError(f"Mission Control env file not found: {ENV_FILE}")
    with open(ENV_FILE, 'r') as f:
        for line in f:
            if line.startswith("LOCAL_AUTH_TOKEN="):
                return line.split("=", 1)[1].strip()
    raise ValueError("LOCAL_AUTH_TOKEN not found in env file")

def invoke_api(path: str, token: str) -> Any:
    headers = {"Authorization": f"Bearer {token}"}
    response = requests.get(f"{API_BASE_URL}{path}", headers=headers)
    response.raise_for_status()
    return response.json()

def get_paged_items(path: str, token: str) -> List[Dict]:
    items = []
    limit = 200
    offset = 0
    while True:
        sep = "&" if "?" in path else "?"
        response = invoke_api(f"{path}{sep}limit={limit}&offset={offset}", token)
        batch = response.get("items", response if isinstance(response, list) else [])
        items.extend(batch)
        if len(batch) < limit:
            break
        offset += limit
    return items

def get_openclaw_agents() -> Dict:
    if not OPENCLAW_JSON.exists():
        raise FileNotFoundError(f"openclaw.json not found: {OPENCLAW_JSON}")
    with open(OPENCLAW_JSON, 'r') as f:
        config = json.load(f)
    agents = []
    by_id = {}
    by_session = {}
    for item in config.get("agents", {}).get("list", []):
        agent_id = item.get("id")
        workspace = item.get("workspace")
        name = item.get("name") or agent_id
        if not agent_id or not workspace:
            continue
        agent = {
            "AgentId": agent_id,
            "Name": name,
            "Workspace": workspace,
            "SessionId": f"agent:{agent_id}:main"
        }
        agents.append(agent)
        by_id[agent_id] = agent
        by_session[agent["SessionId"]] = agent
    return {
        "Agents": agents,
        "ById": by_id,
        "BySession": by_session
    }

def convert_to_safe_name(value: str, fallback: str) -> str:
    safe = re.sub(r'[<>:"/\\|?*]', '-', value)
    safe = re.sub(r'\s+', ' ', safe)
    safe = safe.strip(' .')
    return safe if safe else fallback

def get_unique_name(name: str, used_names: set, suffix: str) -> str:
    if name not in used_names:
        return name
    counter = 1
    while True:
        candidate = f"{name} ({suffix})" if counter == 1 else f"{name} ({suffix}-{counter})"
        if candidate not in used_names:
            return candidate
        counter += 1

def resolve_openclaw_agent(mc_agent: Dict, by_id: Dict, by_session: Dict) -> Optional[Dict]:
    session_id = mc_agent.get("openclaw_session_id")
    if session_id and session_id in by_session:
        return by_session[session_id]
    if mc_agent.get("is_board_lead") and mc_agent.get("board_id"):
        lead_id = f"lead-{mc_agent['board_id']}"
        if lead_id in by_id:
            return by_id[lead_id]
    candidates = [
        mc_agent.get("id"),
        f"mc-{mc_agent.get('id')}",
        mc_agent.get("name")
    ]
    for candidate in candidates:
        if candidate and candidate in by_id:
            return by_id[candidate]
    return None

def write_planned_link(link_path: Path, target_path: str):
    print(f"[planned-link] {link_path} -> {target_path}")
    if not Path(target_path).exists():
        print(f"[warning] Target path does not exist: {target_path}")
    if link_path.exists():
        import subprocess
        subprocess.run(['rm', '-f', str(link_path)], check=True)
    import os
    try:
        os.symlink(target_path, str(link_path))
        print(f"[success] Symlink created: {link_path} -> {target_path}")
    except FileExistsError:
        print(f"[warning] Symlink already exists, skipping: {link_path}")
        pass

def write_markdown_file(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

def get_board_readme_content(board: Dict, linked_agents: List[Dict], missing_agents: List[Dict]) -> str:
    lines = [f"# {board['name']}", ""]
    lines.append(f"- Board ID: '{board['id']}'")
    lines.append(f"- Mission Control URL: {UI_BASE_URL}/boards/{board['id']}")
    desc = board.get("description")
    if desc:
        lines.extend(["", "## Description", "", desc])
    lines.extend(["", "## Linked Workspaces", ""])
    for agent in linked_agents:
        lines.extend([
            f"- **{agent['Name']}**  ",
            f"  MC Agent ID: `{agent['MissionControlId']}`  ",
            f"  OpenClaw ID: `{agent['OpenClawId']}`  ",
            f"  Workspace: `{agent['WorkspaceLinuxPath']}`",
            ""
        ])
    if missing_agents:
        lines.extend(["## Missing Workspace Mappings", ""])
        for agent in missing_agents:
            lines.append(f"- **{agent['Name']}** (`{agent['MissionControlId']}`)")
        lines.append("")
    return "\n".join(lines)

def get_agents_readme_content(agents: List[Dict]) -> str:
    lines = ["# Agents", "", f"Mission Control URL: {UI_BASE_URL}/agents", ""]
    for agent in agents:
        lines.extend([
            f"- **{agent['Name']}**  ",
            f"  OpenClaw ID: `{agent['AgentId']}`  ",
            f"  Workspace: `{agent['Workspace']}`",
            ""
        ])
    return "\n".join(lines)

def get_root_readme_content(board_count: int, agent_count: int, output_path: str) -> str:
    return f"""# Mission Control Links

This folder is generated by create-workspace-symlinks.py.

- Boards UI: {UI_BASE_URL}/boards
- Agents UI: {UI_BASE_URL}/agents
- Output root: {output_path}
- Boards discovered: {board_count}
- OpenClaw agents discovered: {agent_count}

The script creates native Linux symlinks and README files from the live Mission Control state."""

def main():
    try:
        token = get_local_auth_token()
        openclaw = get_openclaw_agents()
        try:
            boards = sorted(get_paged_items("/api/v1/boards", token), key=lambda b: b.get("name", ""))
            mission_control_agents = get_paged_items("/api/v1/agents", token)
        except requests.exceptions.RequestException as e:
            print(f"[warning] Could not connect to Mission Control API: {e}")
            print("Proceeding with only OpenClaw agents symlinks.")
            boards = []
            mission_control_agents = []
    except Exception as e:
        print(f"[error] Failed to initialize: {e}")
        return

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    (OUTPUT_ROOT / "boards").mkdir(exist_ok=True)
    (OUTPUT_ROOT / "agents").mkdir(exist_ok=True)

    agent_links_dir = OUTPUT_ROOT / "agents"
    board_links_dir = OUTPUT_ROOT / "boards"

    used_agent_names = set()
    board_members_for_cleanup = []

    # Process agents
    for agent in sorted(openclaw["Agents"], key=lambda a: (a["Name"], a["AgentId"])):
        safe_name = convert_to_safe_name(agent["Name"], agent["AgentId"])
        link_name = get_unique_name(safe_name, used_agent_names, agent["AgentId"][:8])
        used_agent_names.add(link_name)
        link_path = agent_links_dir / link_name
        write_planned_link(link_path, agent["Workspace"])

    agents_readme = get_agents_readme_content(openclaw["Agents"])
    write_markdown_file(agent_links_dir / "README.md", agents_readme)

    used_board_names = set()
    linked_board_count = 0

    for board in boards:
        board_id = board.get("id")
        board_name = board.get("name")
        if not board_id or not board_name:
            print(f"[warning] Skipping board with invalid ID or name: ID='{board_id}', Name='{board_name}'")
            continue
        members = [a for a in mission_control_agents if a.get("board_id") == board_id]
        if not members:
            continue

        board_safe_name = convert_to_safe_name(board_name, board_id)
        board_folder_name = get_unique_name(board_safe_name, used_board_names, board_id[:8])
        used_board_names.add(board_folder_name)
        board_folder_path = board_links_dir / board_folder_name
        board_folder_path.mkdir(exist_ok=True)

        linked_agents = []
        missing_agents = []
        used_member_names = set()

        for member in sorted(members, key=lambda m: (not m.get("is_board_lead", False), m.get("name", ""), m.get("id", ""))):
            resolved = resolve_openclaw_agent(member, openclaw["ById"], openclaw["BySession"])
            if not resolved:
                missing_agents.append({
                    "Name": member.get("name", ""),
                    "MissionControlId": member.get("id", "")
                })
                continue
            board_members_for_cleanup.append({"Member": member, "Resolved": resolved})

            safe_member_name = convert_to_safe_name(resolved["Name"], resolved["AgentId"])
            member_link_name = get_unique_name(safe_member_name, used_member_names, member["id"][:8])
            used_member_names.add(member_link_name)
            member_link_path = board_folder_path / member_link_name
            write_planned_link(member_link_path, resolved["Workspace"])

            linked_agents.append({
                "Name": resolved["Name"],
                "MissionControlId": member["id"],
                "OpenClawId": resolved["AgentId"],
                "WorkspaceLinuxPath": resolved["Workspace"]
            })

        board_readme = get_board_readme_content(board, linked_agents, missing_agents)
        write_markdown_file(board_folder_path / "README.md", board_readme)
        linked_board_count += 1

    root_readme = get_root_readme_content(linked_board_count, len(openclaw["Agents"]), str(OUTPUT_ROOT))
    write_markdown_file(OUTPUT_ROOT / "README.md", root_readme)

    print(f"\nPrepared output folder: {OUTPUT_ROOT}")
    print(f"Boards with members: {linked_board_count}")
    print(f"OpenClaw agents: {len(openclaw['Agents'])}")

if __name__ == "__main__":
    main()