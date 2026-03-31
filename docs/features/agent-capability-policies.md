# Agent capability policies

Mission Control can now store a managed capability policy on each agent via the agent editor.

This is intended for a central gateway-main or admin workflow that provisions access on a least-access basis.

## What the policy carries

- Policy name
- Allowed board secret keys
- Required board secret keys
- Allowed skills
- Approved file access roots
- Free-form operator notes

The policy is stored in the agent's `identity_profile.capabilities` block.

## What is enforced today

- Agent secret access is filtered to the configured `secret_keys` list when the agent calls `GET /api/v1/agent/secrets`.
- Provisioned `TOOLS.md` only lists the secrets visible to that agent.
- Provisioned `TOOLS.md` includes the managed policy so the agent can see its approved skills and file roots.

## Current workflow

1. Use a central admin or gateway-main process to decide what a lead or worker needs.
2. Open the agent in Mission Control and edit the managed access policy.
3. Save the agent. Mission Control reprovisions the workspace.
4. The agent will see the policy in `TOOLS.md`, and secret exposure will narrow immediately on the next secret fetch.

## Important limitation

Skills and file roots are policy-guided in this first cut. They are visible in provisioning output and can be used by a central superuser workflow, but they are not yet hard-enforced by a dedicated runtime sandbox patch from Mission Control.

## Missing-secret escalation via Gateway Main (POC)

Board Leads can now request secret access help from Gateway Main when they are blocked, or when a managed specialist is blocked.

### New endpoint

- `POST /api/v1/agent/boards/{board_id}/gateway/main/request-secret`

Payload fields:

- `secret_key`: required secret key name (normalized to uppercase)
- `content`: why work is blocked and what is needed
- `target_agent_id`: optional specialist agent id needing the secret
- `target_agent_name`: optional specialist name when id is not known
- `correlation_id`: optional trace token

Behavior:

- Requires board-lead agent auth (`X-Agent-Token`).
- Dispatches a structured message to Gateway Main.
- Instructs Gateway Main to post resolution updates into board memory as non-chat entries.
- Records activity events for sent/failed dispatches.

### E2E POC script

1. Pick board lead token and board id.
2. Trigger a missing-secret request.
3. Confirm API accepted the request.
4. Inspect board memory for gateway-main follow-up.

Example:

```bash
BOARD_ID="<board-uuid>"
LEAD_TOKEN="<board-lead-auth-token>"

curl -s -X POST "http://localhost:8002/api/v1/agent/boards/${BOARD_ID}/gateway/main/request-secret" \
	-H "X-Agent-Token: ${LEAD_TOKEN}" \
	-H "Content-Type: application/json" \
	-d '{
		"secret_key": "GITHUB_TOKEN",
		"content": "Release specialist is blocked on push/tag operations.",
		"target_agent_name": "Release Specialist",
		"correlation_id": "poc-secret-req-001"
	}' | jq .

curl -s "http://localhost:8002/api/v1/agent/boards/${BOARD_ID}/memory?is_chat=false" \
	-H "X-Agent-Token: ${LEAD_TOKEN}" | jq '.items[0:10]'
```
