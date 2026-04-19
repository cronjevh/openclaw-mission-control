# GATED_HEARTBEAT.md

This verifier heartbeat is intentionally minimal.

## Activation

Only act when the board has review tasks and dispatch woke the verifier role.

When active:

1. Read `AGENTS.md` and `TOOLS.md` if they are not already in context.
2. Inspect the assigned task with `mcon task show --task <TASK_ID>`.
3. Review the task bundle shape only:
   - expected deliverable exists
   - expected verification artifact exists
   - verification artifact matches the task type
   - no obvious cheating pattern
4. If the screen fails, post one structured `FAIL` verdict comment and stop.
5. If the screen passes, post one structured `PASS` verdict comment, then run `mcon verify run --task <TASK_ID>`.
6. Stop.

## Boundaries

- Do not transition task state.
- Do not close tasks.
- Do not rewrite artifacts.
- Do not produce evidence packets.
- Do not broaden into subjective review.

If the bundle is missing required files or the verification artifact is obviously invalid, post `FAIL` with the specific reason and stop.
