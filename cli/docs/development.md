# Development Guide

## Adding a New Command

### Step-by-Step

1. **Define requirements**: command path, API endpoint, permissions, args/validation
2. **Update RBAC** in `Rbac.psm1` `$script:Permissions` if the action should be restricted
3. **Add library module** in `scripts/lib/<Module>.psm1` with the core logic
4. **Import module** in `mcon.ps1` at the top import block
5. **Add command routing** in `mcon.ps1` switch block with arg parsing and validation
6. **Update help text** in `mcon.ps1` help heredoc
7. **Update README.md** commands table

### Conventions

- **Approved verbs only**: Use `Get-`, `Invoke-`, `New-`, `Publish-`, `Restore-`, `Test-`, `Write-`, `Resolve-`, `Convert-`, `Initialize-`, `Unlock-`, `Request-`. Avoid `Ensure-`, `Try-`, `Release-`, or hyphenated compound verbs.
- **Export one entry point**: Each module exports only the primary function (e.g., `Invoke-MconAssign`). Internal helpers stay unexported.
- **No comments**: The codebase follows a no-comments convention.
- **Arg parsing**: Use while loop with switch for flags. Validate UUIDs with regex, statuses with `Test-MconValidStatus`.
- **API calls**: Always use `Invoke-MconApi` for consistency and error handling.
- **Errors**: Use `Write-MconError` with codes (`validation`, `forbidden`, `api_error`, `config_error`).
- **Output**: Use `Write-MconResult` for structured JSON on success.
- **Config**: Use `Resolve-MconKeybagAgent` for commands that auto-detect workspace identity.
- **Security**: Use `Crypto.psm1` for any sensitive data operations.

### Module Template

```powershell
function Invoke-MconMyFeature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$SomeArg
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token

    # Core logic here

    return [ordered]@{
        ok     = $true
        action = 'myfeature'
        result = $result
    }
}

Export-ModuleMember -Function Invoke-MconMyFeature
```

### Command Routing Template

```powershell
'mycommand' {
    $myArg = $null
    $i = 0
    while ($i -lt $remaining.Count) {
        switch ($remaining[$i]) {
            '--my-arg' { $myArg = $remaining[++$i]; break }
            default { Write-MconError -Message "Unknown flag: $($remaining[$i])" -Code 'usage' }
        }
        $i++
    }

    if (-not $myArg) {
        Write-MconError -Message '--my-arg is required.' -Code 'usage'
    }

    $agentConfig = Resolve-MconKeybagAgent
    if (-not $agentConfig) {
        Write-MconError -Message "No agent configuration found." -Code 'config_error'
    }

    $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
    $actionKey = 'mycommand.action'
    if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
        $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
        Write-MconError -Message $msg -Code 'forbidden'
    }

    try {
        $result = Invoke-MconMyFeature -Config $agentConfig -SomeArg $myArg
        Write-MconResult -Data ([ordered]@{
            ok     = $true
            action = 'mycommand.action'
            result = $result
        })
    } catch {
        Write-MconError -Message $_.Exception.Message -Code 'myfeature_error'
    }
}
```

## Testing

### Smoke Tests (offline)

```bash
pwsh -File scripts/smoke-test.ps1
```

Validates parsing, error handling, and permissions without API access.

### Live Tests (API integration)

```bash
pwsh -File scripts/live-test.ps1
```

End-to-end tests against a running Mission Control API. Requires real workspace with keybag.

### Manual Testing

```bash
# From a lead workspace
cd ~/.openclaw/workspace-lead-*
mcon workflow dispatch

# From a gateway workspace
cd ~/.openclaw/workspace-gateway-*
mcon admin gettokens
```

## Module Reference

### Config.psm1

Resolves `MCON_*` configuration from multiple sources in priority order.

Key exports:
- `Resolve-MconConfig` - Returns `base_url`, `auth_token`, `board_id`, `wsp`
- `Resolve-MconKeybagAgent` - Decrypts keybag, matches agent by `$PWD`, returns full agent config including `workspace_path` and `agent_id`
- `Test-MconValidStatus` / `Get-MconValidStatuses` - Status enum validation

### Api.psm1

HTTP helpers for Mission Control board API.

Key exports:
- `Invoke-MconApi` - Generic API call with auth headers and error handling
- `Get-MconTask` - Fetch single task
- `Send-MconComment` - Post comment to task
- `Set-MconTaskStatus` - Patch task status
- `New-MconTask` - Create a new task

### Rbac.psm1

Role derivation and permission enforcement.

Key exports:
- `Resolve-MconRole` - Maps workspace prefix to base role
- `Resolve-MconExecutionRole` - Refines worker role to verifier based on AGENTS.md
- `Test-MconPermission` - Checks if role can perform action
- `Get-MconDeniedMessage` - Formats denial message

### Crypto.psm1

AES-256 encryption for keybag and secrets.

Key exports:
- `Protect-MconData` / `Unprotect-MconData` - Encrypt/decrypt strings
- `Protect-MconFile` / `Unprotect-MconFile` - Encrypt/decrypt files
- `New-MconKey` - Generate encryption key

### Admin.psm1

Token management and keybag operations.

Key exports:
- `Invoke-MconAdminGetTokens` - Fetch all agents, derive tokens, write encrypted keybag
- `Invoke-MconAdminDecryptKeybag` - Decrypt keybag to plaintext JSON

### Dispatch.psm1

Board state evaluation. Evaluates memory for pause/resume, checks task queues based on role (lead: inbox/review, worker: assigned tasks), builds taskData.json bundles.

Key exports:
- `Invoke-MconDispatch` - Full dispatch evaluation, returns act/reason/tasks result

### DispatchBoard.psm1

Sequential board-wide dispatch. Fetches all agents for a board, orders them (lead first, then workers, then verifiers), and dispatches each one in sequence with a configurable delay between agents. Changes directory to each agent's workspace before dispatching.

Key exports:
- `Invoke-MconDispatchBoard` - Sequential dispatch across all board agents
- `Get-MconBoardAgentsOrdered` - Fetch and order board agents (lead, workers, verifiers)

### Heartbeat.psm1

Heartbeat queue and OpenClaw gateway session management. File-based queue with pending/processing/failed directories, atomic locking, and process spawning.

Key exports:
- `Invoke-MconHeartbeatQueueProcessor` - Process all queued heartbeat items
- `Add-MconHeartbeatQueueItem` - Enqueue a dispatch state
- `Start-MconHeartbeatQueueProcessor` - Spawn background processor
- `Invoke-MconRecoveryPrompt` - Send recovery prompt to stalled subagent

### Assign.psm1

Worker handoff workflow. Builds bootstrap bundle with task context and project knowledge, spawns worker subagent via OpenClaw, patches task assignment and status.

Key exports:
- `Invoke-MconAssign` - Full assignment workflow with optional `--bundle-only` and `--dry-run`

### Blocker.psm1

Blocked-task escalation workflow. Posts a lead-facing blocker comment and transitions the task to `blocked`.

Key exports:
- `Invoke-MconBlocker` - Raise a blocker on a task from a worker or verifier workspace

### Escalate.psm1

Lead escalation workflow. Routes lead-owned blockers through Gateway Main using either the ask-user or request-secret endpoints.

Key exports:
- `Invoke-MconEscalate` - Escalate a lead blocker to Gateway Main

### TemplateDist.psm1

Template distribution system. Fetches agent details, classifies into lead/worker/verifier families, renders `BOARD_{ROLE}_*.md` templates with variable substitution, and writes to agent workspaces. Supports reverse-render to extract templates from live workspaces.

Key exports:
- `Invoke-MconTemplateDist` - Fetch agents and distribute (or reverse-render) templates

### Verify.psm1

Verification execution. Runs verification scripts or evaluation specs against task deliverables and applies pass/fail outcomes to the board.

Key exports:
- `Invoke-MconVerifyRun` - Execute verification and apply outcome

### Cron.psm1

Board cadence management. Generates a single crontab entry per board that runs `mcon workflow dispatchboard` at the configured interval, replacing the previous per-agent cron approach.

Key exports:
- `Invoke-MconAdminCron` - Set board cadence and update crontab
