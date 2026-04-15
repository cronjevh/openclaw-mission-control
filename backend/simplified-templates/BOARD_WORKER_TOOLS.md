# TOOLS.md

BASE_URL={{base_url}}
AUTH_TOKEN={{auth_token}}
AGENT_NAME={{name}}
AGENT_ID={{id}}

BOARD_ID={{board_id}}


WORKSPACE_ROOT={{workspace_root}}

WORKSPACE_PATH={{workspace_path}}


- `BASE_URL={{base_url}}`
- `AUTH_TOKEN={{auth_token}}`
- `AGENT_NAME={{name}}`
- `AGENT_ID={{id}}`

- `BOARD_ID={{board_id}}`


- `WORKSPACE_ROOT={{workspace_root}}`

- `WORKSPACE_PATH={{workspace_path}}`

- Required tools: `curl`, `jq`





## OpenAPI refresh (run before API-heavy work)

```bash
mkdir -p api
curl -fsS "http://localhost:8002/openapi.json" -o api/openapi.json
jq -r '
  .paths | to_entries[] as $p
  | $p.value | to_entries[]
  | select((.value.tags // []) | index("agent-worker"))
  | "\(.key|ascii_upcase)\t\($p.key)\t\(.value.operationId // "-")\t\(.value[\"x-llm-intent\"] // "-")\t\(.value[\"x-when-to-use\"] // [] | join(\" | \"))\t\(.value[\"x-routing-policy\"] // [] | join(\" | \"))"
' api/openapi.json | sort > api/agent-worker-operations.tsv
```

## API source of truth
- `api/openapi.json`
- `api/agent-worker-operations.tsv`
  - Columns: METHOD, PATH, OP_ID, X_LLM_INTENT, X_WHEN_TO_USE, X_ROUTING_POLICY

## API discovery policy
- Use operations tagged `agent-worker`.
- Prefer operations whose `x-llm-intent` and `x-when-to-use` match the current objective.
- Derive method/path/schema from `api/openapi.json` at runtime.
- Do not hardcode endpoint paths in markdown files.

## API safety
If no confident match exists for current intent, ask one clarifying question.
## Board Documents


No board documents available yet.


## Managed Capability Policy


No managed capability policy assigned. This agent currently inherits the board's full secret set and default workspace behavior.


## Board Secrets


No secrets are currently available to this agent. If work needs credentials outside this policy, escalate to the gateway main / admin flow first.


**Always fetch secrets at runtime via API — never hardcode values:**

```bash
AUTH_TOKEN=$(grep '^AUTH_TOKEN=' TOOLS.md | head -n1 | cut -d= -f2 | tr -d '`')

# Fetch all board secrets and export as env vars
eval $(curl -s -X GET "http://localhost:8002/api/v1/agent/secrets" \
  -H "X-Agent-Token: $AUTH_TOKEN" | \
  jq -r '.[] | "export \(.key)=\(.value | @sh)"')

# Then use normally, e.g.:
# git clone https://x-access-token:${GITHUB_ACCESS_TOKEN}@github.com/org/repo.git
```

**Rules:**
- Fetch once per session/task, not on every command.
- Never log, print, or store the fetched values anywhere.
- If a needed key is missing from the API response, follow the Credentials Protocol in `AGENTS.md`.

## Git Identity

**Always set before any git commit:**

```bash
git config --global user.name "agent"
git config --global user.email "agent@teamosis.com"
```

- Every agent uses the same identity: name `agent`, email `agent@teamosis.com`.
- Never use your own agent name or any other identity.
- Set this at the start of any session involving git operations.

## Browser Access

You have access to a shared Chromium browser via the `browser` tool. Use it when a task requires visiting a website, filling a form, taking screenshots, scraping dynamic content, or interacting with web UIs.

### How to use

The browser connects to a shared headless Chromium instance (port 18800). Always use `target="host"`:

```
browser(action="open", url="https://example.com", target="host")
browser(action="snapshot", target="host", targetId="<id from open>")
browser(action="screenshot", target="host", targetId="<id>")
browser(action="act", target="host", targetId="<id>", request={"kind": "click", "ref": "<ref>"})
browser(action="navigate", target="host", targetId="<id>", url="https://...")
```

### Typical workflow

1. `browser(action="open", url="...", target="host")` — get `targetId`
2. `browser(action="snapshot", ...)` — read the page structure and get element refs
3. `browser(action="act", ..., request={"kind": "click", "ref": "eXX"})` — interact
4. `browser(action="screenshot", ...)` — capture for visual confirmation

### Rules

- Always pass `target="host"` — never omit it
- Use refs from `snapshot` for clicking/typing (e.g. `ref="e12"`)
- After navigation, take a fresh snapshot to get updated refs
- If the page requires login and you don't have credentials, ask before proceeding
- Do NOT use the browser for tasks that can be done with `web_fetch` or `exec/curl` — reserve it for JS-heavy sites and interactive flows
