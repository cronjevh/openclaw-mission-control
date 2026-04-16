BASE_URL={{base_url}}
AGENT_NAME={{name}}
AGENT_ID={{id}}
AUTH_TOKEN={{auth_token}}
BOARD_ID={{board_id}}
WORKSPACE_ROOT=~/.openclaw
WORKSPACE_PATH=~/.openclaw/workspace-lead-{{board_id}}
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
