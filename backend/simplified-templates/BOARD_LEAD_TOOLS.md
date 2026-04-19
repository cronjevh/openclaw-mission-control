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

## Failure Handling

- If `mcon` returns a validation or permission error, correct the command or choose the proper workflow script.
- If `mcon` returns a config error, stop and report the problem instead of searching for tokens.
- If `mcon` returns an API error, treat it as an operational issue, not a cue to improvise direct API access.
