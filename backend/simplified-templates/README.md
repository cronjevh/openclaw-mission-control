# Simplified Templates

This folder contains a lightweight template system for reverse-engineering and replaying board agent workspace files.

The goal is simple:

1. Extract template variables from the current `BOARD_*.md` copies.
2. Fetch live agent data from the board API.
3. Render those templates back into the agent workspaces.

## What lives here

- `BOARD_WORKER_AGENTS.md`
- `BOARD_WORKER_TOOLS.md`
- `BOARD_WORKER_GATED-HEARTBEAT.md`
- `BOARD_WORKER_SOUL.md`
- `BOARD_VERIFIER_AGENTS.md`
- `BOARD_VERIFIER_TOOLS.md`
- `BOARD_VERIFIER_GATED_HEARTBEAT.md`
- `BOARD_VERIFIER_SOUL.md`
- `BOARD_LEAD_AGENTS.md`
- `BOARD_LEAD_TOOLS.md`
- `BOARD_LEAD_GATED-HEARTBEAT.md`
- `BOARD_LEAD_SOUL.md`
- `scripts/extract-vars.ps1`
- `scripts/fetch-agents.ps1`

## Current workflow

### 1. Extract template variables

`scripts/extract-vars.ps1` scans the template copies for templated values and writes the merged variable list to:

- `backend/simplified-templates/.env`

### 2. Fetch agent details

`scripts/fetch-agents.ps1` reads `LOCAL_AUTH_TOKEN` from `backend/.env`, calls:

- `http://localhost:8002/api/v1/agents`

It then fetches each agent detail record and stores a JSON snapshot at:

- `backend/simplified-templates/template-update.json`

### 3. Render templates

The script classifies each agent into one of three template families:

- worker agents -> `BOARD_WORKER_*.md`
- verifier agents with role `verifier` -> `BOARD_VERIFIER_*.md`
- lead agents -> `BOARD_LEAD_*.md`

It renders the matching template set into the live workspace root:

- `/home/cronjev/.openclaw`

Worker output paths:

- `/home/cronjev/.openclaw/workspace-mc-<agent_id>/`

Verifier output paths:

- `/home/cronjev/.openclaw/workspace-mc-<agent_id>/`

Lead output paths:

- `/home/cronjev/.openclaw/workspace-lead-<board_id>/`

Agents without a clear render target are skipped.

## Template variables

The render script uses agent data plus derived values such as:

- `{{base_url}}`
- `{{auth_token}}`
- `{{board_id}}`
- `{{name}}`
- `{{id}}`
- `{{workspace_root}}`
- `{{workspace_path}}`
- `{{identity_profile.role}}`
- `{{identity_template}}`

## Notes

- The script is intentionally lightweight and local-first.
- It is safe to use for validation because it only writes to the configured render root.
- The live workspace is the source of truth for reverse-engineering template values.
- The `testmerge/` folder is useful as a temporary sandbox if you want to redirect output during experiments.

## Common changes

- Add new template variables by updating `scripts/fetch-agents.ps1`.
- Add new template files by following the existing `BOARD_WORKER_*.md` and `BOARD_LEAD_*.md` naming pattern.
- If the board API shape changes, update the fetch/normalization logic before touching the templates.

## Related files

- `backend/.env`
- `backend/simplified-templates/scripts/extract-vars.ps1`
- `backend/simplified-templates/scripts/fetch-agents.ps1`
- `backend/simplified-templates/template-update.json`
