# mcon CLI

**Mission Control CLI** - A PowerShell-based control-plane interface for agents and scripts to interact with Mission Control boards and tasks.

## Overview

`mcon` provides secure, programmatic access to Mission Control's task management API with role-based access control, automatic workspace configuration, and encrypted credential management. It is designed for reliability, extensibility, and agent autonomy in Mission Control workflows.

## Quick Start

### Prerequisites

- PowerShell 7+ (Linux/Mac/Windows)
- Access to Mission Control API (localhost:8002 or remote)
- Agent workspace directory (e.g., `~/.openclaw/workspace-lead-*`)

### Installation

```bash
git clone <repo>
cd mcon-cli
chmod +x scripts/mcon.ps1 scripts/bin/mcon
```

Optionally add the bash wrapper to your PATH:

```bash
cp scripts/bin/mcon ~/bin/mcon
chmod +x ~/bin/mcon
export PATH="$HOME/bin:$PATH"
```

### Usage

```bash
mcon help                              # Show all commands
mcon task show --task <UUID>           # View task details
mcon task create --title "New task" [--backlog false]   # Create a new task
mcon workflow dispatch                  # Evaluate board state, enqueue heartbeat
mcon workflow submitreview --task <UUID>  # Submit completed task for review
mcon admin gettokens                   # Fetch and encrypt agent credentials
```

The CLI auto-detects the workspace from `$PWD`, decrypts the keybag, and executes with the correct role and permissions.

## Commands

| Command | Description | Roles |
|---------|-------------|-------|
| `mcon task show --task <ID>` | View task details | all |
| `mcon task comment --task <ID> --message <TEXT>` | Add comment to task | all |
| `mcon task move --task <ID> --status <STATUS>` | Change task status | gateway |
| `mcon task create --title <TITLE> [--backlog <true\|false>]` | Create a new task | all |
| `mcon admin gettokens` | Fetch agents, derive tokens, encrypt keybag | gateway |
| `mcon admin decrypt-keybag` | Decrypt `.agent-tokens.json.enc` | gateway |
| `mcon admin templatedist --templates-dir <DIR>` | Render and distribute workspace templates | gateway |
| `mcon workflow dispatch` | Evaluate board state, enqueue heartbeat items | lead, worker, verifier |
| `mcon workflow dispatch --process-queue` | Process queued heartbeat items | lead, worker, verifier |
| `mcon workflow assign --task <ID> --worker <ID>` | Assign task to worker agent | lead |
| `mcon workflow blocker --task <ID> --message <TEXT>` | Mark task blocked and escalate to lead | worker, verifier |
| `mcon workflow escalate --message <TEXT> [--secret-key <KEY>]` | Escalate a lead blocker to Gateway Main | lead |
| `mcon workflow submitreview --task <ID>` | Submit task for review with deliverables | worker, verifier |
| `mcon verify run --task <ID>` | Execute verification and apply outcome | verifier |

## Architecture

- **Entry point**: `scripts/mcon.ps1` - argument parsing, auto-config, command routing
- **Library modules**: `scripts/lib/*.psm1` - domain-specific logic, each independently testable
- **Bash wrapper**: `scripts/bin/mcon` - invokes PowerShell without `pwsh -f` prefix
- **Config sources** (priority): env vars > `.mcon.env` > TOOLS.md > encrypted keybag

### Library Modules

| Module | Purpose |
|--------|---------|
| `Config.psm1` | Configuration resolution from env, files, and encrypted keybag |
| `Api.psm1` | HTTP helpers for Mission Control board API calls |
| `Output.psm1` | JSON response formatting and structured error output |
| `Rbac.psm1` | Role derivation and permission checks |
| `Crypto.psm1` | AES-256 encryption/decryption for keybag |
| `Admin.psm1` | Token management and keybag generation |
| `Dispatch.psm1` | Board state evaluation and dispatch gate logic |
| `Heartbeat.psm1` | Heartbeat queue management and OpenClaw gateway integration |
| `Assign.psm1` | Worker handoff: bootstrap bundle, spawn, task assignment |
| `Blocker.psm1` | Worker/verifier blocker escalation and blocked-state transition |
| `Escalate.psm1` | Lead escalation workflow for Gateway Main ask-user and request-secret routes |
| `SubmitReview.psm1` | Task review submission with deliverable validation |
| `TemplateDist.psm1` | Template rendering and distribution to agent workspaces |
| `Verify.psm1` | Verification execution and outcome application |

## Roles & Permissions

Roles are derived from the workspace directory name:

| Workspace prefix | Base role |
|-----------------|-----------|
| `workspace-lead-*` | lead |
| `workspace-gateway-*` | gateway |
| `workspace-mc-*` | worker (or verifier if AGENTS.md declares it) |

Permissions matrix:

| Action | lead | gateway | worker | verifier |
|--------|------|---------|--------|----------|
| `task.show` | yes | yes | yes | yes |
| `task.comment` | yes | yes | yes | yes |
| `task.move` | | yes | | |
| `admin.gettokens` | | yes | | |
| `admin.decrypt-keybag` | | yes | | |
| `admin.templatedist` | | yes | | |
| `workflow.dispatch` | yes | | yes | yes |
| `workflow.assign` | yes | | | |
| `workflow.blocker` | | | yes | yes |
| `workflow.escalate` | yes | | | |
| `workflow.submitreview` | | | yes | yes |
| `verify.run` | | | | yes |

## Security

- **Keybag**: AES-256 encrypted JSON at `scripts/.agent-tokens.json.enc`
- **Key**: Derived from `~/.mcon-secret.key`
- **Tokens**: HMAC-SHA256 signed (`mission-control-agent-token:v1:<agent_id>`)
- **API Auth**: `X-Agent-Token` header

## Configuration

Environment variables (or `.mcon.env`):

| Variable | Purpose |
|----------|---------|
| `MCON_BASE_URL` | API endpoint (e.g., `http://localhost:8002`) |
| `MCON_AUTH_TOKEN` | Agent auth token |
| `MCON_BOARD_ID` | Board UUID |
| `MCON_AGENT_ID` | Agent UUID |
| `MCON_WSP` | Workspace name |

## Development

See [docs/development.md](docs/development.md) for guides on adding commands, testing, and extending the CLI.

## File Layout

```
mcon-cli/
  scripts/
    mcon.ps1                    # Entry point
    bin/mcon                    # Bash wrapper
    lib/                        # Library modules
      Config.psm1
      Api.psm1
      Output.psm1
      Rbac.psm1
      Crypto.psm1
      Admin.psm1
      Dispatch.psm1
      Heartbeat.psm1
      Assign.psm1
      Blocker.psm1
      Escalate.psm1
      SubmitReview.psm1
      TemplateDist.psm1
      Verify.psm1
    .agent-tokens.json.enc      # Encrypted keybag (gitignored)
    smoke-test.ps1
    live-test.ps1
  docs/                         # Documentation
  prompts/                      # Handoff prompts
  .mcon.env.example
```
