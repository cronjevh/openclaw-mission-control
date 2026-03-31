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
