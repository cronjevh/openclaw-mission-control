# Backend Templates

This folder contains the Jinja2 templates Mission Control syncs into OpenClaw workspaces.

- Repo path: `backend/templates/`
- Runtime path: `/app/templates`
- Renderer: `backend/app/services/openclaw/provisioning.py` via `_template_env()`

## Managed ownership model

The authoritative managed trio is:

- `AGENTS.md`
- `TOOLS.md`
- `GATED-HEARTBEAT.md`

Those three files are Mission Control managed surfaces. They are overwritten on sync so the
workspace stays aligned with the current routing and ownership contract.

`HEARTBEAT.md` remains separate on purpose. It is still a compatibility/runtime surface and is
preserved across update syncs via `PRESERVE_AGENT_EDITABLE_FILES`.

## Template routing

Board worker managed files come from:

- `AGENTS.md` -> `BOARD_WORKER_AGENTS.md.j2`
- `TOOLS.md` -> `BOARD_WORKER_TOOLS.md.j2`
- `GATED-HEARTBEAT.md` -> `BOARD_WORKER_GATED-HEARTBEAT.md.j2`

Board lead managed files come from:

- `AGENTS.md` -> `BOARD_LEAD_AGENTS.md.j2`
- `TOOLS.md` -> `BOARD_LEAD_TOOLS.md.j2`
- `GATED-HEARTBEAT.md` -> `BOARD_LEAD_GATED-HEARTBEAT.md.j2`

Shared or compatibility surfaces:

- Board worker `HEARTBEAT.md` -> `BOARD_HEARTBEAT.md.j2`
- Board lead `HEARTBEAT.md` -> `BOARD_HEARTBEAT.md.j2`
- Gateway main `AGENTS.md` -> `GATEWAY_MAIN_AGENTS.md.j2`

Selection is defined in:

- `backend/app/services/openclaw/constants.py`
  - `BOARD_WORKER_TEMPLATE_MAP`
  - `BOARD_LEAD_TEMPLATE_MAP`
  - `GATEWAY_MAIN_TEMPLATE_MAP`
- `backend/app/services/openclaw/provisioning.py`
  - `BoardAgentLifecycleManager._template_overrides()`
  - `BoardAgentLifecycleManager._file_names()`
  - `GatewayMainAgentLifecycleManager._template_overrides()`

## Compatibility shims

These legacy-looking board template names are thin shims and not separate sources of truth:

- `BOARD_AGENTS.md.j2` -> includes `BOARD_WORKER_AGENTS.md.j2`
- `BOARD_TOOLS.md.j2` -> includes `BOARD_WORKER_TOOLS.md.j2`
- `BOARD_GATED-HEARTBEAT.md.j2` -> includes `BOARD_WORKER_GATED-HEARTBEAT.md.j2`

Keep them as compatibility entrypoints only. New worker behavior belongs in the
`BOARD_WORKER_*` templates.

## Group lead reservation

`GROUP_LEAD_*` templates are reserved for actual group leads. They are not the source of truth for
board leads or board workers.

## Sync and overwrite policy

File contracts live in `backend/app/services/openclaw/constants.py`:

- `BOARD_WORKER_GATEWAY_FILES`
- `BOARD_LEAD_GATEWAY_FILES`
- `GROUP_LEAD_GATEWAY_FILES`
- `GATEWAY_MAIN_FILES`
- `MANAGED_CORE_FILES`
- `PRESERVE_AGENT_EDITABLE_FILES`

Provisioning behavior lives in `backend/app/services/openclaw/provisioning.py`:

- `_render_agent_file_specs()`
- `BaseAgentLifecycleManager._set_agent_files()`
- `BoardAgentLifecycleManager._stale_file_candidates()`

Current policy:

- Managed trio files are rewritten during sync.
- `HEARTBEAT.md`, `USER.md`, and `MEMORY.md` are preserved during update syncs unless overwrite is explicitly requested.
- Board-lead sync may delete stale lead/worker-era files when they are outside the current contract.

## Rendering notes

The renderer uses:

- `StrictUndefined`
- `autoescape=False`
- `keep_trailing_newline=True`

Context builders:

- `_build_context()` for board-scoped agents
- `_build_main_context()` for gateway-main agents
- `_user_context()` for user fields
- `_identity_context()` for identity fields

## Guardrails

Before changing templates:

1. Do not add new `{{ ... }}` placeholders unless the context builders provide them.
2. Keep the worker/lead ownership split explicit.
3. Do not move managed behavior back into the ambiguous `BOARD_*` shim files.
4. Keep heartbeat-family templates under the injected-context limit tested in `test_template_size_budget.py`.
