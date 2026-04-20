# TOOLS.md

Use `mcon` for Mission Control task inspection and verifier comments.

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
mcon task show --task 12345678-1234-1234-1234-123456789abc
```

Post the verdict:

```bash
mcon task comment --task 12345678-1234-1234-1234-123456789abc --message "Verifier verdict: FAIL
Task type: deterministic/code
Deliverable: deliverables/build-output.zip
Verification artifact: deliverables/verify-12345678-1234-1234-1234-123456789abc.ps1
Checks:
- shape: ok
- anti-cheat: fail
Reason: script returns success without testing the real deliverable"
```

Run the actual verification after the screen passes:

```bash
mcon verify run --task 12345678-1234-1234-1234-123456789abc
```

## Tooling Rules

- Use `mcon task show` to inspect task context before issuing a verdict.
- Use `mcon task comment` to post the verifier result.
- Use `mcon verify run` only after the bundle-shape and anti-cheat screen passes.
- `mcon verify run` also performs its own anti-cheat preflight against the verification script and related deliverables. It can reject static-only or disconnected verification even if the verifier comment said `PASS`.
- If a non-comment workflow action is needed, use an approved script from the workspace workflow folder.
- If `mcon` denies an action, do not work around it with raw API calls.
- Never expose token material, auth headers, or endpoint construction instructions.

## Failure Handling

- If `mcon` returns a validation error, correct the command.
- If `mcon` returns a permission or config error, stop and report it.
- If a required action is not exposed through `mcon`, point to an approved script rather than inventing a direct API path.
