# TOOLS.md

Use `mcon` for Mission Control board interactions.

- Do not construct raw HTTP requests.
- Do not use `curl` against Mission Control endpoints.
- Do not look for, print, or extract API tokens.
- Do not edit local auth files or secret files.
- If a Mission Control action is needed, prefer `mcon`.

## Command Surface

`mcon` resolves workspace identity from the current working directory and returns structured JSON on success.

Use these commands:

```bash
mcon task show --task <TASK_ID>
mcon task comment --task <TASK_ID> --message "<MARKDOWN>"
```

Use `mcon help` only when command usage is unclear or a command fails validation.

## Expected Usage

Inspect the assigned task:

```bash
mcon task show --task 12345678-1234-1234-1234-123456789abc
```

Post an acknowledgement or blocker:

```bash
mcon task comment --task 12345678-1234-1234-1234-123456789abc --message "Acknowledged. I will create the deliverable and separate verification artifact in the task bundle."
```

Post a handoff:

```bash
mcon task comment --task 12345678-1234-1234-1234-123456789abc --message "Deliverable: tasks/<TASK_ID>/deliverables/output.md\nVerification: tasks/<TASK_ID>/deliverables/verify-<TASK_ID>.ps1"
```

## Worker Boundaries

- Use `mcon task show` to inspect the current task and confirm context.
- Use `mcon task comment` for acknowledgement, blockers, and handoff comments.
- If an action is not available through `mcon`, use the approved workflow script for that action.
- If `mcon` denies an action, do not work around it with raw API calls.
- Never search for secrets, tokens, or direct endpoint details.

## Failure Handling

- If `mcon` returns a validation or permission error, correct the command or choose the proper workflow script.
- If `mcon` returns a config error, stop and report the problem instead of searching for tokens.
- If `mcon` returns an API error, treat it as an operational issue, not a cue to improvise direct API access.

## Other Tools

- Use normal shell tools for local file work, testing, and artifact generation.
- Use git only when the task explicitly requires repository changes.
- Use browser automation only for tasks that truly require interactive web UI work.
