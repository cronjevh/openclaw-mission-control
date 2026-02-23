# Workspace Deliverables

## Overview

The **Deliverables** panel in the task sidebar surfaces files from agent workspaces that are relevant to a task. Agents write files into their workspaces as they work; this panel makes those outputs visible to human reviewers without needing SSH or shell access.

## Where It Appears

In the task detail sidebar, between **Approvals** and **Comments**. It is auto-expanded when files are present.

## How It Works

### File Discovery

1. Backend queries the `agents` table for agents on the board.
2. For each agent, it resolves the workspace path via `openclaw.json` (matched by config ID embedded in `openclaw_session_id`).
3. Files are listed recursively from that workspace root.

### Task Scoping

When `?task_id=<id>` is passed, the endpoint only returns files explicitly referenced in task comments (regex match on file paths/names). This scopes the panel to work relevant to the selected task.

### Download

Downloads use the Clerk JWT (via `customFetch`) → blob URL → programmatic anchor click. Direct URLs are not used because they would 401 without a token.

## API

### List files

```
GET /api/v1/boards/{board_id}/workspace/files
GET /api/v1/boards/{board_id}/workspace/files?task_id={task_id}
```

Response:
```json
{
  "data": [
    { "name": "report.md", "path": "report.md", "is_dir": false, "size": 2048 }
  ]
}
```

### Read a file

```
GET /api/v1/boards/{board_id}/workspace/file?path={relative_path}
```

Response:
```json
{
  "data": { "path": "report.md", "content": "...", "size": 2048 }
}
```

## Infrastructure Requirements

The backend container must have the OpenClaw workspace and config mounted read-only:

```yaml
# compose.yml
volumes:
  - /root/.openclaw/workspace:/root/.openclaw/workspace:ro
  - /root/.openclaw/openclaw.json:/root/.openclaw/openclaw.json:ro
```

These mounts are already present in the default `compose.yml`.

## Task Creator Display

The task card and task detail sidebar show a **Created by** field using `creator_name` from the task API response. This is populated server-side from `tasks.created_by_user_id → users.name` at read time.

In the task board, each task card shows `by <creator_name>` in small text beneath the card metadata.
