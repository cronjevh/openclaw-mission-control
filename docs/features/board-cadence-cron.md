# Board Cadence Cron Integration

## Overview

The board edit page includes a `Board cadence (minutes)` field. This is the frontend
control for board-level scheduling. The browser does not create cron entries directly.
It writes `cadence_minutes` onto the board record, and the backend turns that value
into the scheduled job.

## Frontend flow

The current flow lives in `frontend/src/app/boards/[boardId]/edit/page.tsx`:

1. Open a board edit page.
2. Enter a positive integer in `Board cadence (minutes)`.
3. Save the board.
4. The page sends `cadence_minutes` in the `BoardUpdate` payload.
5. Blank input is converted to `null`, which disables the cadence.

The input is validated on the client as a positive integer or blank. The board edit
form keeps cadence in the same save path as the rest of the board metadata.

## Current UI behavior

- The label shown in the form is `Board cadence (minutes)`.
- The helper text currently says:
  `Optional: set a default cron cadence for workers (in minutes). Leave empty to use board group heartbeat settings.`
- The page also shows a separate `Agent heartbeat` section when the board belongs to a
  group. That section applies board-group heartbeat settings and is not the same as the
  board cadence field.

## Backend effect

When `cadence_minutes` changes, the board update endpoint persists the new value and
enqueues crontab regeneration.

The generated cadence is minute-based cron syntax:

- `1` becomes `*/1 * * * *`
- `5` becomes `*/5 * * * *`
- `null` removes the generated board cron entry

The implementation that performs this work is in:

- `backend/app/api/boards.py`
- `backend/app/services/board_cadence_crontab.py`
- `backend/app/schemas/boards.py`

## Where the cron jobs live

The generated schedule is written as a system cron fragment, not a per-user crontab
entry.

- Default path: `/etc/cron.d/mission-control-board-<board-id-prefix>`
- Naming pattern: the first 8 characters of the board UUID are used in the filename
- The file content contains a standard cron line plus the user field

That is why `crontab -l` does not show it. `crontab -l` only lists the current user's
personal crontab spool. Entries in `/etc/cron.d` are separate system cron files.

In the current compose setup, the queue worker service is the process that writes the
file, and `/etc/cron.d` is mounted into that container so the generated fragment lands
on the host-visible cron directory.

## What this is not

- It is not a client-side timer.
- It is not a browser scheduler.
- It is not the board-group heartbeat editor shown lower on the same page.

## Operational shape

The frontend sets board intent only. The backend owns the actual scheduling outcome
and regenerates the board-level cron file from the saved board record.

## Local API Gate

Generated board cadence entries run through:

```text
/home/cronjev/mission-control-tfsmrt/scripts/cron/mission-control-cron-runner.sh
```

The runner serializes API-touching cron work with a local `flock`, adds small jitter,
and retries commands that fail with HTTP 429 / `Too Many Requests`. This prevents
multiple minute-aligned board and utility jobs from sharing the same backend
agent-auth rate-limit window at the same time.
