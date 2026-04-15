BASE_URL=http://localhost:8002
AGENT_NAME=Atlas
AGENT_ID=febf4a7c-b5d1-4141-bfab-2fea20d8107f
AUTH_TOKEN=mca_xx5UV9D94l3Rzs8CFI939vwRtxeYBgmmemYiYEavqo0
BOARD_ID=dd95369d-1497-41f2-8aeb-e06b51b63162
WORKSPACE_ROOT=~/.openclaw
WORKSPACE_PATH=~/.openclaw/workspace-lead-dd95369d-1497-41f2-8aeb-e06b51b63162
TASK_LIST_ROUTE_TEMPLATE=/api/v1/agent/boards/{board_id}/tasks
TASK_DETAIL_ROUTE_TEMPLATE=/api/v1/agent/boards/{board_id}/tasks/{task_id}
FORBIDDEN_TASK_ROUTE_1=/api/v1/agent/tasks
FORBIDDEN_TASK_ROUTE_2=/api/v1/tasks
CANONICAL_IN_PROGRESS_PATH=/api/v1/agent/boards/$BOARD_ID/tasks?status=in_progress
FAST_QUERY_IN_PROGRESS_COMMAND=curl -fsS "$BASE_URL/api/v1/agent/boards/$BOARD_ID/tasks?status=in_progress" -H "X-Agent-Token: $AUTH_TOKEN"
FAST_QUERY_STATUS_COMMAND_TEMPLATE=curl -fsS "$BASE_URL/api/v1/agent/boards/$BOARD_ID/tasks?status={status}" -H "X-Agent-Token: $AUTH_TOKEN"
FAST_QUERY_ALL_TASKS_COMMAND=curl -fsS "$BASE_URL/api/v1/agent/boards/$BOARD_ID/tasks?limit=200" -H "X-Agent-Token: $AUTH_TOKEN"
FAST_QUERY_BOARD_AGENTS_COMMAND=curl -fsS "$BASE_URL/api/v1/agents?board_id=$BOARD_ID&limit=100" -H "Authorization: Bearer $AUTH_TOKEN"
FAST_QUERY_BACKLOG_COMMAND=curl -fsS "$BASE_URL/api/v1/agent/boards/$BOARD_ID/tasks?status=inbox" -H "X-Agent-Token: $AUTH_TOKEN" | jq -r '.items | map(select(.custom_field_values.backlog == true)) | if length>0 then .[] | "[" + .id + "] " + .title + " (" + (.priority // "-") + ", due: " + (.due_at // "-") + ")" else "No backlog items in inbox" end'
