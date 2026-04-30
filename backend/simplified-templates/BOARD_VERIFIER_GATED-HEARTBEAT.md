# GATED_HEARTBEAT.md

This verifier heartbeat is intentionally minimal.

## Activation

Only act when the board has review tasks and dispatch woke the verifier role.

When active:

1. Read `AGENTS.md` and `TOOLS.md` if they are not already in context.
2. Inspect the assigned task with `mcon task show --task <TASK_ID>`.
3. Review the task bundle shape:
   - expected deliverable bundle exists
   - expected verification artifact set exists
   - verification artifacts match the task type
   - for documentation or planning tasks, both `evaluate-<TASK_ID>.json` and `verify-<TASK_ID>.ps1` are present
   - the wrapper or script appears tied to the real implementation files, not just filenames or docs
   - no obvious cheating pattern
4. Post one structured verdict comment (PASS or FAIL).
5. If the verifier identifies issues requiring targeted rework with custom feedback, use `mcon workflow rework --task <TASK_ID> --worker <AGENT_ID> --message <FEEDBACK>` to explicitly dispatch rework. 
6. Only if verifier verdict is PASS, run `mcon verify run --task <TASK_ID>` to execute automated verification and apply the outcome:
   - `mcon verify run` will perform its own anti-cheat preflight over the verification script and related deliverables before executing the script.
   - for documentation or planning tasks, `mcon verify run` should execute `verify-<TASK_ID>.ps1`; `evaluate-<TASK_ID>.json` is supporting input, not the runnable verifier by itself
   - If PASS: task moves to `done`
   - If FAIL: task moves to `in_progress` and rework is automatically dispatched to the existing worker session
7. Do not move tasks to `inbox` manually. Failed verification always transitions to `in_progress` with rework dispatched to the worker — moving to `inbox` loses the worker assignment and causes unnecessary lead re-assignment delays.
8. Stop.

## Session Scope

- This heartbeat runs in the task-scoped verifier session for the current review task.
- Use the `sessionKey` provided by dispatch as authoritative for this turn.
- Do not switch to the verifier agent's main session and do not reconstruct context from memory or from the gateway main agent.
- If the session key task:<TASK_ID> does not match the task ID being reviewed, you're operating in the wrong session, and you should run `mcon workflow blocker` providing the lead agent with diagnostic detail about how the session started incorrectly.

## Boundaries

- Do not transition task state manually (do not use `mcon task move` to change status).
- Do not move tasks to `inbox` — failed verification goes to `in_progress` with automatic rework dispatch.
- Do not close tasks.
- Do not rewrite artifacts.
- Do not produce evidence packets.
- Do not broaden into subjective review.

If the bundle is missing required files or the verification artifacts are obviously invalid, post `FAIL` with the specific reason and stop.
