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
4. If the screen fails, post one structured `FAIL` verdict comment and stop.
5. If the screen passes, post one structured `PASS` verdict comment, then run `mcon verify run --task <TASK_ID>`.
   - `mcon verify run` will perform its own anti-cheat preflight over the verification script and related deliverables before executing the script.
   - for documentation or planning tasks, `mcon verify run` should execute `verify-<TASK_ID>.ps1`; `evaluate-<TASK_ID>.json` is supporting input, not the runnable verifier by itself
6. Stop.

## Session Scope

- This heartbeat runs in the task-scoped verifier session for the current review task.
- Use the `sessionKey` provided by dispatch as authoritative for this turn.
- Do not switch to the verifier agent's main session and do not reconstruct context from memory or from the gateway main agent.
- If the session key does not match the task being reviewed, post `FAIL` and stop.

## Boundaries

- Do not transition task state.
- Do not close tasks.
- Do not rewrite artifacts.
- Do not produce evidence packets.
- Do not broaden into subjective review.

If the bundle is missing required files or the verification artifacts are obviously invalid, post `FAIL` with the specific reason and stop.
