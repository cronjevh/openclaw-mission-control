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
the key to a command from the utility job scripts configuration.

Two configuration options:

### Option A – Config file (recommended)

Set `MC_UTILITY_JOB_SCRIPTS_FILE` to the path of a JSON file, e.g.:

```bash
MC_UTILITY_JOB_SCRIPTS_FILE=config/utility_job_scripts.json
```

File contents:

```json
{
  "daily_conversation_review": {
    "label": "Daily conversation review",
    "description": "Compile conversation context and create the daily review task.",
    "command": "/home/cronjev/mission-control-tfsmrt/scripts/jobs/daily-conversation-review.ps1"
  }
}
```

### Option B – Inline JSON (legacy)

Set `MC_UTILITY_JOB_SCRIPTS_JSON` to a JSON string:

```bash
MC_UTILITY_JOB_SCRIPTS_JSON='{"daily_conversation_review":{"label":"Daily conversation review","description":"...","command":"/path/to/script.ps1"}}'
```

### Default

If neither variable is set, the MVP exposes a default `daily_conversation_review` script key pointing at:

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

## Local API Gate

Generated utility cron entries run through:

```text
/home/cronjev/mission-control-tfsmrt/scripts/cron/mission-control-cron-runner.sh
```

The runner serializes API-touching cron work with a local `flock`, adds small jitter,
and retries commands that fail with HTTP 429 / `Too Many Requests`. This keeps
minute-aligned jobs from stampeding the backend agent-auth rate limiter while still
using system cron as the scheduler.

Tuning environment variables:

- `MC_CRON_GATE_LOCK_FILE` defaults to `/tmp/mission-control-api-cron.lock`
- `MC_CRON_GATE_LOCK_WAIT_SECONDS` defaults to `3600`
- `MC_CRON_GATE_JITTER_MAX_SECONDS` defaults to `20`
- `MC_CRON_GATE_RETRY_COUNT` defaults to `3`
- `MC_CRON_GATE_RETRY_BASE_SECONDS` defaults to `30`
- `MC_CRON_GATE_COOLDOWN_SECONDS` defaults to `10`
