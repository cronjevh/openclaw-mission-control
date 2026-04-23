# Mission Control Workspace Links

`scripts/workspace-symlinks/create-workspace-symlinks.py` creates native Linux symlinks for browsing agent workspaces in WSL2.

Current behavior:

- Creates `boards/` and `agents/` folders under `/home/cronjev/mission-control-tfsmrt/workspaces`.
- Writes markdown `README.md` files so the structure is useful.
- Resolves board names from Mission Control API and workspace paths from `.openclaw/openclaw.json`.
- Creates native Linux symlinks directly to the workspace paths.
- If Mission Control API is unavailable, proceeds with agent symlinks only.

Example:

```bash
cd /home/cronjev/mission-control-tfsmrt
python3 scripts/workspace-symlinks/create-workspace-symlinks.py
```

Default output:

```text
/home/cronjev/mission-control-tfsmrt/workspaces
```

To run when Mission Control backend is available (for board mappings):

1. Start the backend: `cd backend && uv run uvicorn app.main:app --reload --port 8000`
2. Run the script.

The script handles API unavailability gracefully and creates agent symlinks regardless.
