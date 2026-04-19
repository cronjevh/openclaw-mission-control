#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mission Control CLI (mcon) - stable control-plane interface for agents and scripts.
.DESCRIPTION
    Provides subcommands for interacting with Mission Control boards/tasks.
    Output is structured JSON on success, non-zero exit on failure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$libDir = Join-Path $PSScriptRoot 'lib'
Import-Module (Join-Path $libDir 'Config.psm1') -Force
Import-Module (Join-Path $libDir 'Api.psm1') -Force
Import-Module (Join-Path $libDir 'Output.psm1') -Force
Import-Module (Join-Path $libDir 'Rbac.psm1') -Force
Import-Module (Join-Path $libDir 'Crypto.psm1') -Force
Import-Module (Join-Path $libDir 'Admin.psm1') -Force
Import-Module (Join-Path $libDir 'Dispatch.psm1') -Force
Import-Module (Join-Path $libDir 'Heartbeat.psm1') -Force
Import-Module (Join-Path $libDir 'Assign.psm1') -Force
Import-Module (Join-Path $libDir 'Blocker.psm1') -Force
Import-Module (Join-Path $libDir 'Escalate.psm1') -Force
Import-Module (Join-Path $libDir 'SubmitReview.psm1') -Force
Import-Module (Join-Path $libDir 'TemplateDist.psm1') -Force
Import-Module (Join-Path $libDir 'Verify.psm1') -Force

if ($args.Count -lt 1) {
    Write-MconError -Message 'Usage: mcon <subcommand> [options]. Run ''mcon help'' for details.' -Code 'usage'
}

$subcommand = $args[0]
$remaining = @($args | Select-Object -Skip 1)

switch ($subcommand) {
    'help' {
        $helpText = @'
mcon - Mission Control CLI

Usage:
  mcon task show        --task <TASK_ID>
  mcon task comment    --task <TASK_ID> --message <TEXT>
  mcon task move       --task <TASK_ID> --status <STATUS>
  mcon task create     --title <TITLE> [--description <TEXT>] [--priority <LEVEL>] [--backlog <true|false>] [--tags <TAG_ID1,TAG_ID2,...>]
  mcon admin gettokens      # gateway-only: fetch agents, derive tokens, encrypt keybag
  mcon admin decrypt-keybag # gateway-only: decrypt .agent-tokens.json.enc → .agent-tokens.json
  mcon admin templatedist --templates-dir <DIR> [--output <FILE>] [--render-root <DIR>] [--reverse]  # distribute templates
  mcon workflow dispatch              # evaluate board state, enqueue heartbeat
  mcon workflow dispatch --process-queue  # process queued heartbeat items
  mcon workflow assign --task <TASK_ID> --worker <AGENT_ID>  # assign task to worker
  mcon workflow blocker --task <TASK_ID> --message <TEXT>  # mark task blocked and escalate to lead
  mcon workflow escalate --message <TEXT> [--secret-key <KEY>] [--task <TASK_ID>]  # escalate a lead blocker to Gateway Main
  mcon workflow submitreview --task <TASK_ID> [--message <TEXT>]  # submit task for review
  mcon verify run --task <TASK_ID>    # verifier-only: execute verification and apply outcome

Configuration (env vars, .mcon.env, or TOOLS.md):
  MCON_BASE_URL    API base URL (e.g. http://localhost:8002)
  MCON_AUTH_TOKEN  Agent auth token (X-Agent-Token)
  MCON_BOARD_ID    Default board UUID
  MCON_WSP         Workspace name (e.g. workspace-lead-*, workspace-gateway-*, workspace-mc-*)

Roles (derived from MCON_WSP):
  workspace-lead-*     = lead
  workspace-gateway-*  = gateway
  workspace-mc-*       = worker or verifier (detected from workspace contract)

Permissions:
  task.move            → gateway only
  admin.gettokens      → gateway only
  admin.decrypt-keybag → gateway only
  admin.templatedist   → gateway only
  workflow.dispatch    → lead, worker, verifier
  workflow.blocker     → worker, verifier
  workflow.escalate    → lead
  workflow.submitreview → worker, verifier
  verify.run           → verifier only

Keybag (encrypted JSON):
  Generated:  mcon admin gettokens  → writes .agent-tokens.json.enc
  Decrypted:  mcon admin decrypt-keybag --input ~/.agent-tokens.json.enc --output ~/.agent-tokens.json
  Requires:   ~/.mcon-secret.key (generate: pwsh -Command "New-MconKey -KeyPath '~/.mcon-secret.key'")
  Format:     { version, generated_at, base_url, agents: { id → {id,name,token,workspace_path,is_board_lead,board_id} } }

Statuses: inbox, in_progress, review, done, blocked
'@
        Write-Host $helpText
        exit 0
    }

    'task' {
        if (-not $env:MCON_AUTH_TOKEN) {
            $path = $PWD

            $keybagPath = Join-Path $PSScriptRoot '.agent-tokens.json.enc'
            if (-not (Test-Path -LiteralPath $keybagPath)) {
                Write-Host 'No keys available, run mcon admin gettokens'
                exit 1
            }

            $encContent = Get-Content -LiteralPath $keybagPath -Raw
            $resolvedKey = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('~/.mcon-secret.key')
            if (-not (Test-Path -LiteralPath $resolvedKey)) {
                throw "Key file not found at $resolvedKey."
            }
            $key = Get-Content -Path $resolvedKey -AsByteStream
            $secureString = ConvertTo-SecureString -String $encContent -Key $key
            $bstrPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
            $jsonContent = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrPtr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrPtr)
            $keybag = $jsonContent | ConvertFrom-Json

            $matchingAgent = $null
            foreach ($agentId in $keybag.agents.PSObject.Properties.Name) {
                $agent = $keybag.agents.$agentId
                if ($agent.workspace_path -eq $path) {
                    $matchingAgent = $agent
                    break
                }
            }

            if (-not $matchingAgent) {
                Write-Host "No agent configuration found for workspace path: $path"
                exit 1
            }

            $env:MCON_BASE_URL = if ($keybag.base_url) { $keybag.base_url } else { 'http://localhost:8002' }
            $env:MCON_AUTH_TOKEN = $matchingAgent.token
            $env:MCON_BOARD_ID = $matchingAgent.board_id
            $env:MCON_AGENT_ID = $matchingAgent.id
            $env:MCON_WSP = if ($matchingAgent.is_board_lead) {
                "workspace-lead-$($matchingAgent.board_id)"
            } else {
                "workspace-mc-$($matchingAgent.id)"
            }
        }

        if ($remaining.Count -lt 1) {
            Write-MconError -Message 'Usage: mcon task <action> [options]. Actions: show, comment, move, create.' -Code 'usage'
        }

        $action = $remaining[0]
        $actionArgs = @($remaining | Select-Object -Skip 1)

        $task = $null
        $message = $null
        $status = $null
        $title = $null
        $description = $null
        $priority = $null
        $backlog = $null
        $tags = $null

        $i = 0
        while ($i -lt $actionArgs.Count) {
            switch ($actionArgs[$i]) {
                '--task' { $task = $actionArgs[++$i]; break }
                '--message' { $message = $actionArgs[++$i]; break }
                '--status' { $status = $actionArgs[++$i]; break }
                '--title' { $title = $actionArgs[++$i]; break }
                '--description' { $description = $actionArgs[++$i]; break }
                '--priority' { $priority = $actionArgs[++$i]; break }
                '--backlog' { $backlog = $actionArgs[++$i]; break }
                '--tags' { $tags = $actionArgs[++$i]; break }
                default { Write-MconError -Message "Unknown flag: $($actionArgs[$i])" -Code 'usage' }
            }
            $i++
        }

        if ($action -ne 'create') {
            if (-not $task) {
                Write-MconError -Message '--task <TASK_ID> is required.' -Code 'usage'
            }

            if ($task -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                Write-MconError -Message "Invalid task ID format: $task" -Code 'validation'
            }
        } else {
            if (-not $title) {
                Write-MconError -Message '--title <TITLE> is required for task creation.' -Code 'usage'
            }
        }

        switch ($action) {
            'comment' {
                if (-not $message) {
                    Write-MconError -Message '--message <TEXT> is required.' -Code 'usage'
                }
                if ([string]::IsNullOrWhiteSpace($message)) {
                    Write-MconError -Message 'Message must not be empty.' -Code 'validation'
                }
            }
            'move' {
                if (-not $status) {
                    Write-MconError -Message '--status <STATUS> is required.' -Code 'usage'
                }
                $status = $status.ToLowerInvariant()
                if (-not (Test-MconValidStatus -Status $status)) {
                    $valid = (Get-MconValidStatuses) -join ', '
                    Write-MconError -Message "Invalid status '$status'. Valid: $valid" -Code 'validation'
                }
            }
            'create' {
                if ($null -ne $backlog) {
                    switch (($backlog.ToString()).ToLowerInvariant()) {
                        'true' { $backlog = $true; break }
                        'false' { $backlog = $false; break }
                        default { Write-MconError -Message "--backlog must be 'true' or 'false'." -Code 'validation' }
                    }
                }
                if ($null -ne $tags) {
                    $tagList = @($tags -split ',' | Where-Object { $_.Trim() }) | ForEach-Object { $_.Trim() }
                    foreach ($t in $tagList) {
                        if ($t -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                            Write-MconError -Message "Invalid tag ID format: $t" -Code 'validation'
                        }
                    }
                    $tags = $tagList
                }
            }
        }

        try {
            $config = Resolve-MconConfig
            $workspacePath = Get-MconWorkspacePathFromWsp -Wsp $config.wsp
            $role = Resolve-MconExecutionRole -Wsp $config.wsp -WorkspacePath $workspacePath
        }
        catch {
            Write-MconError -Message $_.Exception.Message -Code 'config_error'
        }

        $actionKey = "task.$action"
        if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
            $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
            Write-MconError -Message $msg -Code 'forbidden'
        }

        switch ($action) {
            'show' {
                try {
                    $result = Get-MconTask -BaseUrl $config.base_url -Token $config.auth_token -BoardId $config.board_id -TaskId $task
                    Write-MconResult -Data ([ordered]@{ ok = $true; task = $result })
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'api_error'
                }
            }
            'comment' {
                try {
                    $result = Send-MconComment -BaseUrl $config.base_url -Token $config.auth_token -BoardId $config.board_id -TaskId $task -Message $message
                    Write-MconResult -Data ([ordered]@{ ok = $true; comment = $result })
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'api_error'
                }
            }
            'move' {
                try {
                    $result = Set-MconTaskStatus -BaseUrl $config.base_url -Token $config.auth_token -BoardId $config.board_id -TaskId $task -Status $status
                    Write-MconResult -Data ([ordered]@{ ok = $true; task = $result })
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'api_error'
                }
            }
            'create' {
                try {
                    $createParams = @{
                        BaseUrl = $config.base_url
                        Token = $config.auth_token
                        BoardId = $config.board_id
                        Title = $title
                        Description = $description
                        Priority = $priority
                    }
                    if ($null -ne $backlog) {
                        $createParams.Backlog = [bool]$backlog
                    }
                    if ($null -ne $tags) {
                        $createParams.TagIds = [string[]]$tags
                    }
                    $result = New-MconTask @createParams
                    Write-MconResult -Data ([ordered]@{ ok = $true; task = $result })
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'api_error'
                }
            }
            default {
                Write-MconError -Message "Unknown task action: $action. Valid: show, comment, move, create." -Code 'usage'
            }
        }
    }

    'workflow' {
        if ($remaining.Count -lt 1) {
            Write-MconError -Message 'Usage: mcon workflow <action>. Actions: dispatch, assign, blocker, escalate, submitreview.' -Code 'usage'
        }

        $wfAction = $remaining[0]
        $wfArgs = @($remaining | Select-Object -Skip 1)

        switch ($wfAction) {
            'dispatch' {
                $processQueue = $false
                $chatLimit = 20
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--process-queue' { $processQueue = $true; break }
                        '--chat-limit' { $chatLimit = [int]$wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                $agentConfig = Resolve-MconKeybagAgent
                if (-not $agentConfig) {
                    Write-MconError -Message "No agent configuration found for current directory. Run from an agent workspace or set MCON_* env vars." -Code 'config_error'
                }

                $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
                $actionKey = 'workflow.dispatch'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                $invocationAgent = if ($role -eq 'lead') { "lead-$($agentConfig.board_id)" } else { "mc-$($agentConfig.agent_id)" }

                if ($processQueue) {
                    try {
                        $result = Invoke-MconHeartbeatQueueProcessor `
                            -WorkspacePath $agentConfig.workspace_path `
                            -InvocationAgent $invocationAgent `
                            -Config $agentConfig `
                            -TimeoutSec 120
                        Write-MconResult -Data ([ordered]@{
                            ok     = $true
                            action = 'workflow.process_queue'
                            result = $result
                        })
                    } catch {
                        Write-MconError -Message $_.Exception.Message -Code 'queue_error'
                    }
                } else {
                    try {
                        $dispatchResult = Invoke-MconDispatch -Config $agentConfig -ChatLimit $chatLimit
                    } catch {
                        $errMsg = $_.Exception.Message
                        if ($errMsg -match 'connect(ion)? refused|No connection could be made|timed out|Failed to connect|Unable to connect|actively refused') {
                            Write-MconError -Message "API backend is not responding. Check that the API service is running." -Code 'api_down'
                        }
                        Write-MconError -Message $errMsg -Code 'dispatch_error'
                    }

                    if ($dispatchResult.act -ne $true) {
                        Write-MconResult -Data ([ordered]@{
                            ok       = $true
                            action   = 'workflow.dispatch'
                            dispatch = $dispatchResult
                        })
                        exit 0
                    }

                    $dispatchStates = @(Get-MconHeartbeatDispatchStates -DispatchResult $dispatchResult)
                    $queued = 0
                    $skipped = 0
                    foreach ($ds in $dispatchStates) {
                        if (Add-MconHeartbeatQueueItem -WorkspacePath $agentConfig.workspace_path -InvocationAgent $invocationAgent -DispatchState $ds) {
                            $queued++
                        } else {
                            $skipped++
                        }
                    }

                    $processingStarted = $false
                    if ($queued -gt 0) {
                        $processingStarted = Start-MconHeartbeatQueueProcessor -WorkspacePath $agentConfig.workspace_path -MconScriptPath $PSCommandPath
                    }

                    Write-MconResult -Data ([ordered]@{
                        ok       = $true
                        action   = 'workflow.dispatch'
                        dispatch = $dispatchResult
                        queue    = [ordered]@{
                            queued             = $queued
                            skipped            = $skipped
                            processing_started = $processingStarted
                        }
                    })
                }
            }

            'assign' {
                $taskId = $null
                $workerAgentId = $null
                $workerWorkspacePath = $null
                $bundleOnly = $false
                $dryRun = $false
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--worker' { $workerAgentId = $wfArgs[++$i]; break }
                        '--worker-workspace' { $workerWorkspacePath = $wfArgs[++$i]; break }
                        '--bundle-only' { $bundleOnly = $true; break }
                        '--dry-run' { $dryRun = $true; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $taskId) {
                    Write-MconError -Message '--task <TASK_ID> is required.' -Code 'usage'
                }
                if (-not $workerAgentId) {
                    Write-MconError -Message '--worker <AGENT_ID> is required.' -Code 'usage'
                }
                if ($taskId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid task ID format: $taskId" -Code 'validation'
                }
                if ($workerAgentId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid worker agent ID format: $workerAgentId" -Code 'validation'
                }

                $agentConfig = Resolve-MconKeybagAgent
                if (-not $agentConfig) {
                    Write-MconError -Message "No agent configuration found for current directory. Run from an agent workspace or set MCON_* env vars." -Code 'config_error'
                }

                $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
                $actionKey = 'workflow.assign'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                try {
                    $assignParams = @{
                        Config        = $agentConfig
                        TaskId        = $taskId
                        WorkerAgentId = $workerAgentId
                    }
                    if ($workerWorkspacePath) { $assignParams.WorkerWorkspacePath = $workerWorkspacePath }
                    if ($bundleOnly) { $assignParams.BundleOnly = $true }
                    if ($dryRun) { $assignParams.DryRun = $true }

                    $result = Invoke-MconAssign @assignParams

                    if ($result.ok) {
                        Write-MconResult -Data ([ordered]@{
                            ok     = $true
                            action = 'workflow.assign'
                            result = $result
                        })
                    } else {
                        Write-MconError -Message "$($result.phase): $($result.error)" -Code 'assign_error'
                    }
                } catch {
                    Write-MconError -Message $_.Exception.Message -Code 'assign_error'
                }
            }

            'blocker' {
                $taskId = $null
                $message = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--message' { $message = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $taskId) {
                    Write-MconError -Message '--task <TASK_ID> is required.' -Code 'usage'
                }
                if ($taskId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid task ID format: $taskId" -Code 'validation'
                }
                if (-not $message) {
                    Write-MconError -Message '--message <TEXT> is required.' -Code 'usage'
                }
                if ([string]::IsNullOrWhiteSpace($message)) {
                    Write-MconError -Message 'Message must not be empty.' -Code 'validation'
                }

                $agentConfig = Resolve-MconKeybagAgent
                if (-not $agentConfig) {
                    Write-MconError -Message "No agent configuration found for current directory. Run from an agent workspace or set MCON_* env vars." -Code 'config_error'
                }

                $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
                $actionKey = 'workflow.blocker'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                try {
                    $result = Invoke-MconBlocker -Config $agentConfig -TaskId $taskId -Message $message -Role $role

                    if ($result.ok) {
                        Write-MconResult -Data ([ordered]@{
                            ok     = $true
                            action = 'workflow.blocker'
                            result = $result
                        })
                    } else {
                        Write-MconError -Message "$($result.message)" -Code $result.code
                    }
                } catch {
                    Write-MconError -Message $_.Exception.Message -Code 'blocker_error'
                }
            }

            'escalate' {
                $taskId = $null
                $message = $null
                $secretKey = $null
                $targetAgentId = $null
                $targetAgentName = $null
                $preferredChannel = $null
                $correlationId = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--message' { $message = $wfArgs[++$i]; break }
                        '--secret-key' { $secretKey = $wfArgs[++$i]; break }
                        '--target-agent' { $targetAgentId = $wfArgs[++$i]; break }
                        '--target-agent-name' { $targetAgentName = $wfArgs[++$i]; break }
                        '--channel' { $preferredChannel = $wfArgs[++$i]; break }
                        '--correlation-id' { $correlationId = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $message) {
                    Write-MconError -Message '--message <TEXT> is required.' -Code 'usage'
                }
                if ([string]::IsNullOrWhiteSpace($message)) {
                    Write-MconError -Message 'Message must not be empty.' -Code 'validation'
                }
                if ($taskId -and $taskId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid task ID format: $taskId" -Code 'validation'
                }
                if ($targetAgentId -and $targetAgentId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid target agent ID format: $targetAgentId" -Code 'validation'
                }
                if ($preferredChannel -and $secretKey) {
                    Write-MconError -Message '--channel is only valid for ask-user escalation without --secret-key.' -Code 'validation'
                }
                if (-not $secretKey -and ($targetAgentId -or $targetAgentName)) {
                    Write-MconError -Message '--target-agent and --target-agent-name require --secret-key.' -Code 'validation'
                }
                if ($secretKey -and [string]::IsNullOrWhiteSpace($secretKey)) {
                    Write-MconError -Message 'Secret key must not be empty.' -Code 'validation'
                }

                $agentConfig = Resolve-MconKeybagAgent
                if (-not $agentConfig) {
                    Write-MconError -Message "No agent configuration found for current directory. Run from an agent workspace or set MCON_* env vars." -Code 'config_error'
                }

                $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
                $actionKey = 'workflow.escalate'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                try {
                    $result = Invoke-MconEscalate `
                        -Config $agentConfig `
                        -Message $message `
                        -TaskId $taskId `
                        -SecretKey $secretKey `
                        -TargetAgentId $targetAgentId `
                        -TargetAgentName $targetAgentName `
                        -PreferredChannel $preferredChannel `
                        -CorrelationId $correlationId

                    if ($result.ok) {
                        Write-MconResult -Data ([ordered]@{
                            ok     = $true
                            action = 'workflow.escalate'
                            result = $result
                        })
                    } else {
                        Write-MconError -Message "$($result.message)" -Code $result.code
                    }
                } catch {
                    Write-MconError -Message $_.Exception.Message -Code 'escalate_error'
                }
            }

            'submitreview' {
                $taskId = $null
                $message = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--message' { $message = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $taskId) {
                    Write-MconError -Message '--task <TASK_ID> is required.' -Code 'usage'
                }
                if ($taskId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid task ID format: $taskId" -Code 'validation'
                }

                $agentConfig = Resolve-MconKeybagAgent
                if (-not $agentConfig) {
                    Write-MconError -Message "No agent configuration found for current directory. Run from an agent workspace or set MCON_* env vars." -Code 'config_error'
                }

                $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
                $actionKey = 'workflow.submitreview'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                try {
                    $result = Invoke-MconSubmitReview -Config $agentConfig -TaskId $taskId -Message $message

                    if ($result.ok) {
                        Write-MconResult -Data ([ordered]@{
                            ok     = $true
                            action = 'workflow.submitreview'
                            result = $result
                        })
                    } else {
                        Write-MconError -Message "$($result.message)" -Code $result.code
                    }
                } catch {
                    Write-MconError -Message $_.Exception.Message -Code 'submitreview_error'
                }
            }

            default {
                Write-MconError -Message "Unknown workflow action: $wfAction. Valid: dispatch, assign, blocker, escalate, submitreview." -Code 'usage'
            }
        }
    }

    'verify' {
        if ($remaining.Count -lt 1) {
            Write-MconError -Message 'Usage: mcon verify <action>. Actions: run.' -Code 'usage'
        }

        $verifyAction = $remaining[0]
        $verifyArgs = @($remaining | Select-Object -Skip 1)

        switch ($verifyAction) {
            'run' {
                $taskId = $null
                $i = 0
                while ($i -lt $verifyArgs.Count) {
                    switch ($verifyArgs[$i]) {
                        '--task' { $taskId = $verifyArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($verifyArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $taskId) {
                    Write-MconError -Message '--task <TASK_ID> is required.' -Code 'usage'
                }
                if ($taskId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid task ID format: $taskId" -Code 'validation'
                }

                $agentConfig = Resolve-MconKeybagAgent
                if (-not $agentConfig) {
                    Write-MconError -Message "No agent configuration found for current directory. Run from an agent workspace or set MCON_* env vars." -Code 'config_error'
                }

                $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
                $actionKey = 'verify.run'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                try {
                    $result = Invoke-MconVerifyRun -Config $agentConfig -TaskId $taskId
                    Write-MconResult -Data ([ordered]@{
                        ok     = $true
                        action = 'verify.run'
                        result = $result
                    })
                } catch {
                    Write-MconError -Message $_.Exception.Message -Code 'verify_error'
                }
            }

            default {
                Write-MconError -Message "Unknown verify action: $verifyAction. Valid: run." -Code 'usage'
            }
        }
    }

    'admin' {
        if ($remaining.Count -lt 1) {
            Write-MconError -Message 'Usage: mcon admin <action>. Actions: gettokens, decrypt-keybag, templatedist.' -Code 'usage'
        }
        $adminAction = $remaining[0]
        $adminArgs = @($remaining | Select-Object -Skip 1)

        $adminConfig = Resolve-MconKeybagAgent
        if (-not $adminConfig) {
            $wsp = Resolve-MconWsp
            if (-not $wsp) {
                Write-MconError -Message 'No agent configuration found. Run from an agent workspace or set MCON_WSP.' -Code 'config_error'
            }
            $adminConfig = [ordered]@{
                wsp            = $wsp
                workspace_path = Get-MconWorkspacePathFromWsp -Wsp $wsp
            }
        }

        $role = Resolve-MconExecutionRole -Wsp $adminConfig.wsp -WorkspacePath $adminConfig.workspace_path

        $actionKey = "admin.$adminAction"
        if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
            $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
            Write-MconError -Message $msg -Code 'forbidden'
        }

        switch ($adminAction) {
            'gettokens' {
                try {
                    Invoke-MconAdminGetTokens -Wsp $adminConfig.wsp
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'api_error'
                }
            }
            'decrypt-keybag' {
                $inputPath = '~/.agent-tokens.json.enc'
                $outputPath = '~/.agent-tokens.json'
                $keyPath = '~/.mcon-secret.key'

                $i = 0
                while ($i -lt $adminArgs.Count) {
                    switch ($adminArgs[$i]) {
                        '--input'  { $inputPath = $adminArgs[++$i]; break }
                        '--output' { $outputPath = $adminArgs[++$i]; break }
                        '--key'    { $keyPath = $adminArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($adminArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                try {
                    Invoke-MconAdminDecryptKeybag -InputPath $inputPath -OutputPath $outputPath -KeyPath $keyPath -Wsp $adminConfig.wsp
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'crypto_error'
                }
            }
            'templatedist' {
                $templatesDir = '/home/cronjev/mission-control-tfsmrt/backend/simplified-templates'
                $tdOutputPath = $null
                $renderRoot = '/home/cronjev/.openclaw'
                $reverseRender = $false
                $tdAgentNames = @()

                $i = 0
                while ($i -lt $adminArgs.Count) {
                    switch ($adminArgs[$i]) {
                        '--templates-dir' { $templatesDir = $adminArgs[++$i]; break }
                        '--output' { $tdOutputPath = $adminArgs[++$i]; break }
                        '--render-root' { $renderRoot = $adminArgs[++$i]; break }
                        '--reverse' { $reverseRender = $true; break }
                        '--agent-name' { $tdAgentNames += $adminArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($adminArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $templatesDir) {
                    Write-MconError -Message '--templates-dir <DIR> is required. Point to the simplified-templates directory.' -Code 'usage'
                }

                $gatewayWorkspace = $adminConfig.workspace_path
                $toolsPath = Join-Path $gatewayWorkspace 'TOOLS.md'
                $localAuthToken = $null
                if (Test-Path -LiteralPath $toolsPath) {
                    $toolsMap = Read-MconToolsMd -Path $toolsPath
                    if ($toolsMap.ContainsKey('LOCAL_AUTH_TOKEN')) {
                        $localAuthToken = $toolsMap['LOCAL_AUTH_TOKEN']
                    }
                }

                if (-not $localAuthToken) {
                    $backendEnvPath = '/home/cronjev/mission-control-tfsmrt/.env'
                    if (Test-Path -LiteralPath $backendEnvPath) {
                        $envMap = Read-MconToolsMd -Path $backendEnvPath
                        if ($envMap.ContainsKey('LOCAL_AUTH_TOKEN')) {
                            $localAuthToken = $envMap['LOCAL_AUTH_TOKEN']
                        }
                    }
                }

                if (-not $localAuthToken) {
                    Write-MconError -Message 'LOCAL_AUTH_TOKEN not found. Set it in gateway TOOLS.md or backend .env.' -Code 'config_error'
                }

                try {
                    $tdParams = @{
                        LocalAuthToken = $localAuthToken
                        RenderRoot     = $renderRoot
                        TemplatesDir   = $templatesDir
                    }
                    if ($tdOutputPath) { $tdParams.OutputPath = $tdOutputPath }
                    if ($reverseRender) { $tdParams.ReverseRender = $true }
                    if ($tdAgentNames.Count -gt 0) { $tdParams.ReverseRenderAgentNames = $tdAgentNames }

                    $result = Invoke-MconTemplateDist @tdParams
                    Write-MconResult -Data ([ordered]@{
                        ok     = $true
                        action = 'admin.templatedist'
                        result = $result
                    })
                } catch {
                    Write-MconError -Message $_.Exception.Message -Code 'templatedist_error'
                }
            }
            default {
                Write-MconError -Message "Unknown admin action: $adminAction. Valid: gettokens, decrypt-keybag, templatedist." -Code 'usage'
            }
        }
    }

    default {
        Write-MconError -Message "Unknown subcommand: $subcommand. Run 'mcon help' for usage." -Code 'usage'
    }
}
