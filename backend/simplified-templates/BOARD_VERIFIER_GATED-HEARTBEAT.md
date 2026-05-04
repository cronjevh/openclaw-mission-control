# GATED_HEARTBEAT.md

This verifier heartbeat is intentionally minimal.

## Activation

CRITICAL: The dispatch snapshot is authoritative for this turn. Do not skip your duties because you suspect stale state, recall prior actions, or believe the task may have changed. If dispatch woke you and the taskData.json shows status: review, you must complete the full verification flow (verdict → mcon verify run) regardless of anything else.

Specifically: Do NOT check the live task API or rely on memory of previous states when deciding whether to act. The fact that dispatch targeted you means the gate evaluated the task was in review at dispatch time. Your job is to verify the bundle that was presented, not to re-check the task status.

When active:

1. Read `AGENTS.md` and `TOOLS.md` if they are not already in context.
2. Read the task's `taskData.json` ( the data was refreshed moments ago by cli scripting )
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

## Stuck Verification Escalation

If a task has failed automated verification **3 or more times** with the same preflight rejection (e.g., "static-only", "missing runtime signals", "does not reference deliverables"), the verifier may dynamically adjust the verification rules instead of repeating the same failure.

Before applying rules, confirm:
- The deliverable bundle is valid and the verification script is syntactically correct.
- The preflight failure is a **category mismatch** (the task's deliverables don't fit the hardcoded profile) rather than a missing or broken verification script.
- The worker has already attempted to fix the script at least twice.

If all above are true, apply targeted rules and re-run:

```bash
mcon verify set-rules --task <TASK_ID> --rules '<JSON>'
mcon verify run --task <TASK_ID>
```

Common rule overrides:
- **Static-only rejection on a file-content verification** (e.g., `workspace_config`):
  `'{"preflight":{"skip_static_only_rejection":true}}'`
- **Deliverable reference rejection when the target is outside the task bundle** (e.g., main workspace file):
  `'{"preflight":{"skip_deliverable_by_filename":true}}'`
- **Require a specific path or pattern** that the preflight should check for:
  `'{"required_patterns":["/home/cronjev/.openclaw/workspace/AGENTS.md"]}'`
- **Forbid dangerous patterns** (e.g., `Start-Process` on Linux):
  `'{"forbidden_patterns":["Start-Process"]}'`

After applying rules, post a comment documenting:
1. Why the task was stuck.
2. What rules were applied.
3. The outcome of the subsequent `mcon verify run`.

Do not use `verify.set-rules` to bypass missing verification scripts, broken deliverables, or obvious cheating. It is only for category mismatches where the task's actual deliverables are valid but don't match the default profile expectations.

If the bundle is missing required files or the verification artifacts are obviously invalid, post `FAIL` with the specific reason and stop.
