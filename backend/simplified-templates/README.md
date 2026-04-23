# Simplified Templates

This folder contains the simplified board-agent template sources.

The goal is simple:

1. Keep the worker, verifier, and lead prompt contracts in one place.
2. Evolve those contracts without editing rendered workspace copies by hand.
3. Preserve the design history that informed the current board-role split.

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

## Current workflow

Edit the `BOARD_*.md` files in this directory directly.

- `BOARD_WORKER_*.md` define the worker contract.
- `BOARD_VERIFIER_*.md` define the verifier contract.
- `BOARD_LEAD_*.md` define the lead contract.

There is currently no repo-supported script in this directory for fetching live agent state or replaying these templates into `.openclaw` workspaces.

## Template variables

Some templates still contain placeholder variables such as:

- `{{board_id}}`
- `{{name}}`
- `{{id}}`
- `{{workspace_root}}`
- `{{workspace_path}}`
- `{{identity_profile.role}}`
- `{{identity_template}}`

They remain part of the template source format. No supported renderer currently lives in this folder.

## Notes

- The older local render/sync helpers under `backend/simplified-templates/scripts/` have been removed.
- Treat these files as source templates and design references unless a new supported render path is introduced later.
- The `testmerge/` folder is useful as a temporary sandbox if you want to redirect output during experiments.

## Common changes

- Add new template files by following the existing `BOARD_WORKER_*.md` and `BOARD_LEAD_*.md` naming pattern.
- If a new workspace render path is introduced later, document it here instead of reviving stale instructions.

## Related files

- `backend/.env`
