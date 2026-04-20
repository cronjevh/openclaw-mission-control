# TOOLS.md

Use `mcon` for Mission Control board interactions.

- Do not construct raw HTTP requests.
- Do not use `curl` against Mission Control endpoints.
- Do not look for or extract API tokens.
- Do not edit local auth files.
- If a Mission Control action is needed, only use `mcon`. 

## Command Surface

`mcon` resolves workspace identity from the current working directory and returns structured JSON on success.

Use these commands:

```bash
mcon task show --task <TASK_ID>
mcon task comment --task <TASK_ID> --message "<MARKDOWN>"
```

Use `mcon help` only when command usage is unclear or a command fails validation.

## Expected Usage

Inspect a task:

```bash
mcon task show --task 12345678-1234-1234-1234-123456789abc
```

Post a task update:

```bash
mcon task comment --task 12345678-1234-1234-1234-123456789abc --message "Assigned to Vulcan for implementation."
```

## Lead Boundaries

- Use `mcon task show` to inspect task state before making decisions.
- Use `mcon task comment` to record decisions, assignments, blockers, and follow-up instructions.
- Use `mcon workflow escalate --message "<TEXT>"` when a blocker requires Gateway Main or human input, and add `--secret-key <KEY>` when the blocker is missing secret access.
- If an action is not available through `mcon`, use the approved workflow script for that action.
- If `mcon` denies an action, do not work around it with raw API calls.

## Tooling Gap Failure Boundary

- If a requested board mutation cannot be completed through `mcon` or an already-approved workflow script, stop and report the exact tooling gap.
- Do not write a replacement script, call Mission Control routes directly, or read/extract tokens to work around missing `mcon` functionality.
- Use one short failure message that names the blocked action and missing capability.
- After reporting the gap, stop. Do not continue searching for loopholes in the same turn.

## Board Route Discipline

- Approved board task operations must resolve to board-scoped routes such as `/api/v1/agent/boards/{board_id}/tasks...`.
- Treat non-board task route families such as `/api/v1/agent/tasks` as forbidden references for lead task operations.
- This route discipline applies to `mcon` and approved workflow scripts; it is not permission to fall back to raw HTTP.

## Assignment and Backlog Guardrails

- Treat control-plane notifications as advisory. The live board state is authoritative.
- Before assigning, reassigning, or triggering start-of-work actions, re-fetch live task state and verify `status`, `assigned_agent_id`, and `custom_field_values.backlog`.
- If `custom_field_values.backlog=true`, do not assign the task, do not trigger start-of-work actions, and do not clear backlog on your own authority.
- Never infer backlog state from a top-level `backlog` field when `custom_field_values` is available.
- Dependency resolution, recovery handling, and closure follow-up do not authorize backlog clearing or backlog-gated work start.
- The only valid way to start new work is through the gated heartbeat path driven by `./.openclaw/workflows/mc-board-workflow.ps1`.
- If completed work implies follow-up, you may comment, create a new task, or leave a breadcrumb, but defer new assignment or work-start decisions to the next gated heartbeat evaluation.

## Board Task Fast Path

Use this for direct board-task visibility questions in board chat, such as:

- what is in `inbox`, `in_progress`, `review`, `blocked`, or `done`
- who is assigned to what
- what a named agent is working on

Rules:

1. Read `BASE_URL`, `BOARD_ID`, and `AUTH_TOKEN` from `TOOLS.md`.
2. Use only approved board-scoped task access paths.
3. Make at most one extra board-agent lookup to map IDs to names.
4. Reply immediately with task facts; skip pre-flight chatter, startup narration, and discovery monologue.
5. Never end silently. On failure, emit one short failure line with reason and next retry action.
6. If equivalent task data is already in context this session, answer directly without re-reading.

Response contract:

- First line is a task-fact heading such as `In-progress tasks` or `Board task status`.
- Then one bullet per task: `title (task id) — status: <status>; assignee: <name|agent_id|unassigned>`
- If empty: `none`
- Forbidden first lines include `Pre-flight check`, `Re-reading AUTH_TOKEN`, `verifying API access`, and `Hey — I'm {{name}}`

## Failure Handling

- If `mcon` returns a validation or permission error, correct the command or choose the proper workflow script.
- If `mcon` returns a config error, stop and report the problem instead of searching for tokens.
- If `mcon` returns an API error, treat it as an operational issue, not a cue to improvise direct API access.
