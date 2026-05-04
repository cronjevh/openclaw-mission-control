# TOOLS.md

Use `mcon` for Mission Control task inspection and verifier comments.

- The verifier heartbeat runs in a task-scoped session for the current review task. Do not switch to a main session or rebuild context from memory.

- Do not construct raw HTTP requests.
- Do not use `curl` against Mission Control endpoints.
- Do not search for or print tokens.
- Do not improvise API payloads.

## Command Surface

Use these commands:

```bash
mcon task show --task <TASK_ID>
mcon task comment --task <TASK_ID> --message "<MARKDOWN>"
mcon verify run --task <TASK_ID>
```

Use `mcon help` only when command usage is unclear or validation fails.

## Expected Usage

Inspect the assigned review task:

```bash
mcon task show --task <TASK_ID>
```

Post the verdict and handle the outcome:

```bash
mcon task comment --task <TASK_ID> --message "Verifier verdict: PASS
Task type: deterministic/code
Deliverable: deliverables/build-output.zip
Verification artifacts: deliverables/verify-<TASK_ID>.ps1
Checks:
- shape: ok
- anti-cheat: ok
Reason: bundle shape and anti-cheat checks pass"

mcon verify run --task <TASK_ID>
```

For FAIL verdict, 

```bash
mcon task comment --task <TASK_ID> --message "Verifier verdict: FAIL
Task type: deterministic/code
Deliverable: deliverables/build-output.zip
Verification artifacts: deliverables/verify-<TASK_ID>.ps1
Checks:
- shape: ok
- anti-cheat: fail
Reason: script returns success without testing the real deliverable"

mcon verify run --task <TASK_ID>
```

For documentation or planning tasks, treat:

- `deliverables/evaluate-<TASK_ID>.json` as the worker-authored judge spec
- `deliverables/verify-<TASK_ID>.ps1` as the verification entrypoint that should invoke the configured LLM validation path

## Tooling Rules

- Use `mcon workflow rework` after posting a FAIL verdict
- Use `mcon verify run` after posting a PASS verdict. This triggers the execution of the prepared and vetted verify<TASK_ID>.json which then determines of a task is done, or requires additional rework. 
- For documentation or planning tasks, do not treat `evaluate-<TASK_ID>.json` as the executable verifier by itself; the required runnable entrypoint is `verify-<TASK_ID>.ps1`.
- `mcon verify run` also performs its own anti-cheat preflight against the verification script and related deliverables. It can reject static-only or disconnected verification even if the verifier comment said `PASS`.
- If a non-comment workflow action is needed, use an approved script from the workspace workflow folder.
- If `mcon` denies an action, do not work around it with raw API calls.
- Never expose token material, auth headers, or endpoint construction instructions.
- Use `mcon task comment` to post the verifier result.
- Never use `mcon task show` during normal verification duties, the taskData.json is complee, up-to-date and authoritative at the start of an activation. You may only do an additional `mcon task show` following direct instructions from the user, or if you're troubleshooting verification issues where the standard process are confirmed to have failed.

## Failure Handling

- If `mcon` returns a validation error, correct the command.
- If `mcon` returns a permission or config error, stop and report it.
- If a required action is not exposed through `mcon`, point to an approved script rather than inventing a direct API path.
