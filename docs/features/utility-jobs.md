# Utility Jobs

## Overview

Utility jobs are GUI-managed cron tasks for deterministic scripts. They are intended
for work that should not involve agent decision-making, such as compiling daily
conversation context and creating a review task.

## How It Works

1. An admin creates a job from the Mission Control **Jobs** page.
2. The job stores a cron expression, optional board/agent scope, script key, and JSON
   arguments.
3. The backend validates that the script key is allowlisted.
4. The queue worker writes a generated system cron fragment.
5. System cron runs the configured script on schedule.

The generated file follows this pattern:

```text
/etc/cron.d/mission-control-job-<job-id-prefix>
```

The page does not schedule browser timers, and it does not route through the agent
heartbeat path.

## Script Allowlist

Jobs use a `script_key`, not an arbitrary command entered in the UI. The backend maps
the key to a command from `MC_UTILITY_JOB_SCRIPTS_JSON`.

Example:

```json
{
  "daily_conversation_review": {
    "label": "Daily conversation review",
    "description": "Compile conversation context and create the daily review task.",
    "command": "/home/cronjev/mission-control-tfsmrt/scripts/jobs/daily-conversation-review.ps1"
  }
}
```

If `MC_UTILITY_JOB_SCRIPTS_JSON` is not set, the MVP exposes a default
`daily_conversation_review` script key pointing at:

```text
/home/cronjev/mission-control-tfsmrt/scripts/jobs/daily-conversation-review.ps1
```

## Job Scope

Jobs can be global, board-scoped, or board-agent-scoped.

- Global jobs receive only their configured JSON arguments.
- Board-scoped jobs receive `--board-id <BOARD_ID>`.
- Agent-scoped jobs require a board and receive both `--board-id <BOARD_ID>` and
  `--agent-id <AGENT_ID>`.

JSON arguments are converted to `--key value` command-line pairs.

## Logs

Generated cron entries append stdout/stderr to:

```text
/home/cronjev/.openclaw/logs/jobs/job-<job-id-prefix>.<YYYYMMDD>.log
```

Override the log directory with `MC_UTILITY_JOB_LOG_DIR`.
