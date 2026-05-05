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
mcon task show --task <TASK_ID>
```

Post an acknowledgement:

```bash
mcon task comment --task <TASK_ID> --message "Acknowledged. I will create the deliverable and separate verification artifact in the task bundle."
```

Raise a blocker:

```bash
mcon workflow blocker --task <TASK_ID> --message "Blocked on missing requirement clarification from @lead."
```

Post a handoff:

```bash
mcon task comment --task <TASK_ID> --message "Deliverable: tasks/<TASK_ID>/deliverables/output.md\nVerification: tasks/<TASK_ID>/deliverables/verify-<TASK_ID>.ps1"
```

For documentation or planning tasks, name both verification files:

```bash
mcon task comment --task <TASK_ID> --message "Deliverable: tasks/<TASK_ID>/deliverables/output.md\nEvaluation spec: tasks/<TASK_ID>/deliverables/evaluate-<TASK_ID>.json\nVerification: tasks/<TASK_ID>/deliverables/verify-<TASK_ID>.ps1"
```

Submit the completed task for review:

```bash
mcon workflow submitreview --task <TASK_ID>
```

## Worker Boundaries

- Use `mcon task comment` for acknowledgement and handoff comments.
- Use `mcon workflow blocker` when you are stuck and need lead intervention.
- Use `mcon workflow submitreview` to transition finished work into `review`.
- If an action is not available through `mcon`, use the approved workflow script for that action.
- If `mcon` denies an action, do not work around it with raw API calls.
- Never search for secrets, tokens, or direct endpoint details.
- Never use `mcon task show` on current task, the taskData.json was already updated at the start of the turn. You may use `mcon task` only to look up details from other related tasks if that's needed for you to complete the task.

## Failure Handling

- If `mcon` returns a validation or permission error, correct the command or choose the proper workflow script.
- If `mcon` returns a config error, stop and report the problem instead of searching for tokens.
- If `mcon` returns an API error, treat it as an operational issue, not a cue to improvise direct API access.

## Other Tools

- Use normal shell tools for local file work, testing, and artifact generation.
- Use git only when the task explicitly requires repository changes.
- Use browser automation only for tasks that truly require interactive web UI work.
