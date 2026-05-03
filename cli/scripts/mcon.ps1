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
Import-Module (Join-Path $libDir 'TagSummary.psm1') -Force
Import-Module (Join-Path $libDir 'Rbac.psm1') -Force
Import-Module (Join-Path $libDir 'Crypto.psm1') -Force
Import-Module (Join-Path $libDir 'Admin.psm1') -Force
Import-Module (Join-Path $libDir 'Dispatch.psm1') -Force
Import-Module (Join-Path $libDir 'OpenClawSession.psm1') -Force
Import-Module (Join-Path $libDir 'Heartbeat.psm1') -Force
Import-Module (Join-Path $libDir 'Assign.psm1') -Force
Import-Module (Join-Path $libDir 'Rework.psm1') -Force
Import-Module (Join-Path $libDir 'SyncAllowAgents.psm1') -Force
Import-Module (Join-Path $libDir 'Blocker.psm1') -Force
Import-Module (Join-Path $libDir 'Escalate.psm1') -Force
Import-Module (Join-Path $libDir 'SubmitReview.psm1') -Force
Import-Module (Join-Path $libDir 'TemplateDist.psm1') -Force
Import-Module (Join-Path $libDir 'Verify.psm1') -Force
Import-Module (Join-Path $libDir 'Cron.psm1') -Force
Import-Module (Join-Path $libDir 'DispatchBoard.psm1') -Force

function Get-MconErrorCodeFromException {
    param([Parameter(Mandatory)][System.Exception]$Exception)

    if ($Exception -is [System.Management.Automation.ParameterBindingException]) {
        return 'validation'
    }

    $message = [string]$Exception.Message
    if ($message -match 'Cannot bind parameter|Cannot process argument transformation|Cannot convert value to type') {
        return 'validation'
    }

    return 'api_error'
}

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
   mcon task list        [--board <BOARD_ID>] [--status <STATUS>] [--tag <TAG>] [--assigned <AGENT_ID>] [--unassigned]
  mcon task show        [--board <BOARD_ID>] --task <TASK_ID>
  mcon task show        [--board <BOARD_ID>] --tags <TAG_ID|SLUG|NAME,...>
   mcon task comment    --task <TASK_ID> (--message <TEXT>|--message-file <PATH>)
   mcon task move       --task <TASK_ID> --status <STATUS>
   mcon task move       --task <TASK_ID> --board <BOARD_ID> --comment <TEXT> [--source-board <BOARD_ID>]
  mcon task create     --title <TITLE> [--description <TEXT>|--message-file <PATH>] [--priority <LEVEL>] [--backlog <true|false>] [--tags <TAG_ID,...>] [--depends-on <TASK_ID,...>]
  mcon task update     --task <TASK_ID> [--title <TITLE>] [--description <TEXT>|--message-file <PATH>] [--priority <LEVEL>] [--backlog <true|false>] [--tags <TAG_ID,...>] [--depends-on <TASK_ID,...>]
  mcon admin gettokens      # gateway-only: fetch agents, derive tokens, encrypt keybag
  mcon admin decrypt-keybag # gateway-only: decrypt .agent-tokens.json.enc → .agent-tokens.json
  mcon admin sync-allowagents # gateway-only: sync lead allowAgents in openclaw.json to match board assignments
  mcon admin templatedist --templates-dir <DIR> [--output <FILE>] [--render-root <DIR>] [--reverse]  # distribute templates
  mcon admin cron --board-id <BOARD_ID> --cadence-minutes <INT> [--dry-run] [--crontab-dir <DIR>]  # set board cadence and update crontab
  mcon workflow dispatch              # evaluate board state, enqueue heartbeat
  mcon workflow dispatch --process-queue  # process queued heartbeat items
  mcon workflow dispatchboard --board <BOARD_ID> [--delay <SECONDS>]  # sequential dispatch for all board agents
   mcon workflow assign --task <TASK_ID> --worker <AGENT_ID> [--origin-session-key <task:...|tag:...|agent:...:task:...|agent:...:tag:...>]  # assign task to worker
   mcon workflow rework  --task <TASK_ID> --worker <AGENT_ID> (--message <TEXT>|--message-file <PATH>)  # rework task with existing worker session
    mcon workflow blocker --task <TASK_ID> (--message <TEXT>|--message-file <PATH>)  # mark task blocked and escalate to lead
   mcon workflow escalate (--message <TEXT>|--message-file <PATH>) [--secret-key <KEY>] [--task <TASK_ID>]  # escalate a lead blocker to Gateway Main
  mcon workflow gateway-reply --board <BOARD_ID> (--message <TEXT>|--message-file <PATH>) [--task <TASK_ID>] [--secret-reply]  # gateway-only: reply to board lead
   mcon workflow submitreview --task <TASK_ID> (--message <TEXT>|--message-file <PATH>)  # submit task for review
    mcon verify run --task <TASK_ID>    # verifier-only: execute verification and apply outcome

Roles (derived from MCON_WSP):
  workspace-lead-*     = lead
  workspace-gateway-*  = gateway
  workspace-mc-*       = worker or verifier (detected from workspace contract)

Permissions:
  task.list            → all
  task.move            → gateway only
  task.movetoboard     → gateway, lead only
  task.update          → lead, gateway only
  admin.gettokens      → gateway only
  admin.decrypt-keybag → gateway only
  admin.sync-allowagents → gateway only
  admin.templatedist   → gateway only
  admin.cron           → gateway only
  workflow.dispatch    → lead, worker, verifier
  workflow.dispatchboard → gateway only
  workflow.rework      → lead, verifier only
  workflow.blocker     → worker, verifier
  workflow.escalate    → lead
  workflow.gateway-reply → gateway
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
                # Try resolving symlinks - Get the real path if current path is a symlink
                try {
                    $item = Get-Item -LiteralPath $path -ErrorAction Stop
                    $realPath = if ($item.LinkType -eq 'SymbolicLink' -and $item.Target) {
                        $item.Target
                    } else {
                        $path
                    }
                    foreach ($agentId in $keybag.agents.PSObject.Properties.Name) {
                        $agent = $keybag.agents.$agentId
                        if ($agent.workspace_path -eq $realPath) {
                            $matchingAgent = $agent
                            break
                        }
                    }
                }
                catch {
                    # Ignore resolution errors, fall through to leaf-name matching
                }
            }

            if (-not $matchingAgent) {
                # Fall back to matching by agent name based on directory leaf
                # Extract the leaf directory name from the current path
                $leafName = Split-Path -Leaf $path
                foreach ($agentId in $keybag.agents.PSObject.Properties.Name) {
                    $agent = $keybag.agents.$agentId
                    $agentLeafName = Split-Path -Leaf $agent.workspace_path
                    if ($leafName -eq $agentLeafName) {
                        $matchingAgent = $agent
                        break
                    }
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
            }
            else {
                "workspace-mc-$($matchingAgent.id)"
            }
        }

        if ($remaining.Count -lt 1) {
            Write-MconError -Message 'Usage: mcon task <action> [options]. Actions: list, show, comment, move, create, update.' -Code 'usage'
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
        $dependsOn = $null
        $messageFile = $null
        $targetBoard = $null
        $sourceBoard = $null
        $moveComment = $null
        $listTag = $null
        $listAssigned = $null
        $listUnassigned = $null

        $i = 0
        while ($i -lt $actionArgs.Count) {
            switch ($actionArgs[$i]) {
                '--task' { $task = $actionArgs[++$i]; break }
                '--message' { $message = $actionArgs[++$i]; break }
                '--message-file' { $messageFile = $actionArgs[++$i]; break }
                '--status' { $status = $actionArgs[++$i]; break }
                '--board' { $targetBoard = $actionArgs[++$i]; break }
                '--source-board' { $sourceBoard = $actionArgs[++$i]; break }
                '--tag' { $listTag = $actionArgs[++$i]; break }
                '--assigned' { $listAssigned = $actionArgs[++$i]; break }
                '--unassigned' { $listUnassigned = $true; break }
                '--comment' { $moveComment = $actionArgs[++$i]; break }
                '--title' { $title = $actionArgs[++$i]; break }
                '--description' { $description = $actionArgs[++$i]; break }
                '--priority' { $priority = $actionArgs[++$i]; break }
                '--backlog' { $backlog = $actionArgs[++$i]; break }
                '--tags' { $tags = $actionArgs[++$i]; break }
                '--depends-on' { $dependsOn = $actionArgs[++$i]; break }
                default { Write-MconError -Message "Unknown flag: $($actionArgs[$i])" -Code 'usage' }
            }
            $i++
        }

        if ($action -eq 'show') {
            if ($task -and $tags) {
                Write-MconError -Message 'Use either --task <TASK_ID> or --tags <TAG_ID|SLUG|NAME,...>, not both.' -Code 'usage'
            }
            if (-not $task -and -not $tags) {
                Write-MconError -Message 'task show requires either --task <TASK_ID> or --tags <TAG_ID|SLUG|NAME,...>.' -Code 'usage'
            }
            if ($task -and $task -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                Write-MconError -Message "Invalid task ID format: $task" -Code 'validation'
            }
            if ($targetBoard -and $targetBoard -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                Write-MconError -Message "Invalid board ID format: $targetBoard" -Code 'validation'
            }
            if ($tags) {
                $tags = @(Get-MconTagIdentifierList -Tags $tags)
                if ($tags.Count -eq 0) {
                    Write-MconError -Message '--tags requires at least one tag identifier.' -Code 'usage'
                }
            }
        }
        elseif ($action -ne 'create' -and $action -ne 'list') {
            if (-not $task) {
                Write-MconError -Message '--task <TASK_ID> is required.' -Code 'usage'
            }

            if ($task -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                Write-MconError -Message "Invalid task ID format: $task" -Code 'validation'
            }
        }
        if ($action -eq 'list') {
            if ($targetBoard -and $targetBoard -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                Write-MconError -Message "Invalid board ID format: $targetBoard" -Code 'validation'
            }
            if ($listAssigned -and $listAssigned -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                Write-MconError -Message "Invalid assigned agent ID format: $listAssigned" -Code 'validation'
            }
            if ($listAssigned -and $listUnassigned) {
                Write-MconError -Message 'Use either --assigned <AGENT_ID> or --unassigned, not both.' -Code 'usage'
            }
        }
        elseif ($action -eq 'create') {
            if (-not $title) {
                Write-MconError -Message '--title <TITLE> is required for task creation.' -Code 'usage'
            }
        }

        try {
            $config = Resolve-MconConfig
        }
        catch {
            Write-MconError -Message $_.Exception.Message -Code 'config_error'
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
                if ($status -and $targetBoard) {
                    Write-MconError -Message 'Use either --status <STATUS> for status change or --board <BOARD_ID> for board move, not both.' -Code 'usage'
                }
                if ($status) {
                    $status = $status.ToLowerInvariant()
                    if (-not (Test-MconValidStatus -Status $status)) {
                        $valid = (Get-MconValidStatuses) -join ', '
                        Write-MconError -Message "Invalid status '$status'. Valid: $valid" -Code 'validation'
                    }
                }
                elseif ($targetBoard) {
                    if ($targetBoard -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                        Write-MconError -Message "Invalid target board ID format: $targetBoard" -Code 'validation'
                    }
                    if ($sourceBoard -and $sourceBoard -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                        Write-MconError -Message "Invalid source board ID format: $sourceBoard" -Code 'validation'
                    }
                    if (-not $moveComment) {
                        Write-MconError -Message '--comment <TEXT> is required when moving a task to another board.' -Code 'usage'
                    }
                    if ([string]::IsNullOrWhiteSpace($moveComment)) {
                        Write-MconError -Message 'Comment must not be empty.' -Code 'validation'
                    }
                }
                else {
                    Write-MconError -Message 'task move requires either --status <STATUS> or --board <BOARD_ID> --comment <TEXT>.' -Code 'usage'
                }
            }
            'create' {
                if ($null -ne $messageFile) {
                    if ($null -ne $description) {
                        Write-MconError -Message 'Use either --description <TEXT> or --message-file <PATH>, not both.' -Code 'usage'
                    }
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message "Message file not found: $messageFile" -Code 'validation'
                    }
                    $description = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
                }
                if ($null -ne $backlog) {
                    switch (($backlog.ToString()).ToLowerInvariant()) {
                        'true' { $backlog = $true; break }
                        'false' { $backlog = $false; break }
                        default { Write-MconError -Message "--backlog must be 'true' or 'false'." -Code 'validation' }
                    }
                }
                if ($null -ne $tags) {
                    $tagList = @($tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($tagList.Count -eq 0) {
                        Write-MconError -Message '--tags requires at least one tag identifier.' -Code 'usage'
                    }
                    # Resolve tag identifiers (UUIDs or slugs) to UUIDs
                    try {
                        $resolvedTags = Resolve-MconTagIds -BaseUrl $config.base_url -Token $config.auth_token -BoardId $config.board_id -Identifiers $tagList
                        $tags = $resolvedTags
                    }
                    catch {
                        Write-MconError -Message $_.Exception.Message -Code 'validation'
                    }
                }
                if ($null -ne $dependsOn) {
                    $depList = @($dependsOn -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    foreach ($d in $depList) {
                        if ($d -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                            Write-MconError -Message "Invalid depends-on task ID format: $d" -Code 'validation'
                        }
                    }
                    $dependsOn = $depList
                }
            }
            'update' {
                if ($null -ne $messageFile) {
                    if ($null -ne $description) {
                        Write-MconError -Message 'Use either --description <TEXT> or --message-file <PATH>, not both.' -Code 'usage'
                    }
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message "Message file not found: $messageFile" -Code 'validation'
                    }
                    $description = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
                }
                if ($null -eq $title -and $null -eq $description -and $null -eq $priority -and $null -eq $backlog -and $null -eq $tags -and $null -eq $dependsOn) {
                    Write-MconError -Message 'At least one update field is required (--title, --description, --priority, --backlog, --tags, --depends-on).' -Code 'usage'
                }
                if ($null -ne $backlog) {
                    switch (($backlog.ToString()).ToLowerInvariant()) {
                        'true' { $backlog = $true; break }
                        'false' { $backlog = $false; break }
                        default { Write-MconError -Message "--backlog must be 'true' or 'false'." -Code 'validation' }
                    }
                }
                if ($null -ne $tags) {
                    $tagList = @($tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($tagList.Count -eq 0) {
                        Write-MconError -Message '--tags requires at least one tag identifier.' -Code 'usage'
                    }
                    # Resolve tag identifiers (UUIDs or slugs) to UUIDs
                    try {
                        $resolvedTags = Resolve-MconTagIds -BaseUrl $config.base_url -Token $config.auth_token -BoardId $config.board_id -Identifiers $tagList
                        $tags = $resolvedTags
                    }
                    catch {
                        Write-MconError -Message $_.Exception.Message -Code 'validation'
                    }
                }
                if ($null -ne $dependsOn) {
                    $depList = @($dependsOn -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    foreach ($d in $depList) {
                        if ($d -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                            Write-MconError -Message "Invalid depends-on task ID format: $d" -Code 'validation'
                        }
                    }
                    $dependsOn = $depList
                }
            }
        }

        try {
            $workspacePath = Get-MconWorkspacePathFromWsp -Wsp $config.wsp
            $role = Resolve-MconExecutionRole -Wsp $config.wsp -WorkspacePath $workspacePath
        }
        catch {
            Write-MconError -Message $_.Exception.Message -Code 'config_error'
        }

        $actionKey = if ($action -eq 'move' -and $targetBoard) { 'task.movetoboard' } else { "task.$action" }
        if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
            $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
            Write-MconError -Message $msg -Code 'forbidden'
        }

        switch ($action) {
            'list' {
                try {
                    $effectiveBoard = if ($targetBoard) { $targetBoard } else { $config.board_id }
                    if (-not $effectiveBoard) {
                        Write-MconError -Message 'No board context available. Use --board <BOARD_ID> to specify a board.' -Code 'usage'
                    }
                    if ($effectiveBoard -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                        Write-MconError -Message "Invalid board ID format: $effectiveBoard" -Code 'validation'
                    }
                    $taskParams = @{
                        BaseUrl = $config.base_url
                        Token   = $config.auth_token
                        BoardId = $effectiveBoard
                    }
                    if ($status) { $taskParams.Status = $status }
                    if ($listTag) { $taskParams.Tag = $listTag }
                    if ($listAssigned) { $taskParams.AssignedAgentId = $listAssigned }
                    if ($listUnassigned) { $taskParams.Unassigned = $true }
                    $tasks = Get-MconBoardTasks @taskParams

                    # Filter tasks to ensure they belong to the correct board (defensive programming)
                    $tasks = @($tasks | Where-Object { $_.board_id -eq $effectiveBoard })

                    # Filter out done tasks unless explicitly requested
                    if (-not $status -or $status -notmatch 'done') {
                        $tasks = @($tasks | Where-Object { $_.status -ne 'done' })
                    }

                    Write-MconResult -Data ([ordered]@{
                        ok      = $true
                        board   = $effectiveBoard
                        tasks   = $tasks
                        count   = $tasks.Count
                    })
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code (Get-MconErrorCodeFromException -Exception $_.Exception)
                }
            }
            'show' {
                try {
                    # Determine effective board (--board overrides workspace-resolved board)
                    $effectiveBoard = if ($targetBoard) { $targetBoard } else { $config.board_id }
                    if (-not $effectiveBoard) {
                        Write-MconError -Message 'No board context available. Use --board <BOARD_ID> to specify a board.' -Code 'usage'
                    }
                    if ($effectiveBoard -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                        Write-MconError -Message "Invalid board ID format: $effectiveBoard" -Code 'validation'
                    }

                    if ($task) {
                        $result = Get-MconTask -BaseUrl $config.base_url -Token $config.auth_token -BoardId $effectiveBoard -TaskId $task
                        $comments = Get-MconTaskComments -BaseUrl $config.base_url -Token $config.auth_token -BoardId $effectiveBoard -TaskId $task
                        Write-MconResult -Data ([ordered]@{ ok = $true; task = $result; comments = $comments })
                    }
                    else {
                        $result = Get-MconProjectTagSummaries `
                            -BaseUrl $config.base_url `
                            -Token $config.auth_token `
                            -BoardId $effectiveBoard `
                            -TagIdentifiers ([string[]]$tags)
                        Write-MconResult -Data ([ordered]@{
                                ok             = $true
                                generated_at   = $result.generated_at
                                requested_tags = $result.requested_tags
                                summaries      = $result.summaries
                            })
                    }
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code (Get-MconErrorCodeFromException -Exception $_.Exception)
                }
            }
            'comment' {
                try {
                    $result = Send-MconComment -BaseUrl $config.base_url -Token $config.auth_token -BoardId $config.board_id -TaskId $task -Message $message
                    Write-MconResult -Data ([ordered]@{ ok = $true; comment = $result })
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code (Get-MconErrorCodeFromException -Exception $_.Exception)
                }
            }
            'move' {
                try {
                    if ($targetBoard) {
                        $effectiveSourceBoard = if ($sourceBoard) { $sourceBoard } else { $config.board_id }
                        if (-not $effectiveSourceBoard) {
                            Write-MconError -Message '--source-board <BOARD_ID> is required (no board context from workspace).' -Code 'usage'
                        }

                        $result = Move-MconTaskBetweenBoards -BaseUrl $config.base_url -Token $config.auth_token -TargetBoardId $targetBoard -SourceBoardId $effectiveSourceBoard -TaskId $task -Comment $moveComment

                        Write-MconResult -Data ([ordered]@{
                            ok            = $true
                            action        = 'task.movetoboard'
                            source_board  = $result.source_board_id
                            target_board  = $result.target_board_id
                            source_task   = $result.source_task_id
                            new_task      = $result.new_task_id
                            task          = $result.task
                        })
                    }
                    else {
                        $result = Set-MconTaskStatus -BaseUrl $config.base_url -Token $config.auth_token -BoardId $config.board_id -TaskId $task -Status $status
                        Write-MconResult -Data ([ordered]@{ ok = $true; task = $result })
                    }
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code (Get-MconErrorCodeFromException -Exception $_.Exception)
                }
            }
            'create' {
                try {
                    $createParams = @{
                        BaseUrl     = $config.base_url
                        Token       = $config.auth_token
                        BoardId     = $config.board_id
                        Title       = $title
                        Description = $description
                        Priority    = $priority
                    }
                    if ($null -ne $backlog) {
                        $createParams.Backlog = [bool]$backlog
                    }
                    if ($null -ne $tags) {
                        $createParams.TagIds = [string[]]$tags
                    }
                    if ($null -ne $dependsOn) {
                        $createParams.DependsOnTaskIds = [string[]]$dependsOn
                    }
                    $result = New-MconTask @createParams
                    Write-MconResult -Data ([ordered]@{ ok = $true; task = $result })
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code (Get-MconErrorCodeFromException -Exception $_.Exception)
                }
            }
            'update' {
                try {
                    $updateParams = @{
                        BaseUrl = $config.base_url
                        Token   = $config.auth_token
                        BoardId = $config.board_id
                        TaskId  = $task
                    }
                    if ($null -ne $title) {
                        $updateParams.Title = $title
                    }
                    if ($null -ne $description) {
                        $updateParams.Description = $description
                    }
                    if ($null -ne $priority) {
                        $updateParams.Priority = $priority
                    }
                    if ($null -ne $backlog) {
                        $updateParams.Backlog = [bool]$backlog
                    }
                    if ($null -ne $tags) {
                        $updateParams.TagIds = [string[]]$tags
                    }
                    if ($null -ne $dependsOn) {
                        $updateParams.DependsOnTaskIds = [string[]]$dependsOn
                    }
                    $result = Set-MconTask @updateParams
                    Write-MconResult -Data ([ordered]@{ ok = $true; task = $result })
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code (Get-MconErrorCodeFromException -Exception $_.Exception)
                }
            }
            default {
                Write-MconError -Message "Unknown task action: $action. Valid: show, comment, move, create, update." -Code 'usage'
            }
        }
    }

    'workflow' {
        if ($remaining.Count -lt 1) {
            Write-MconError -Message 'Usage: mcon workflow <action>. Actions: dispatch, dispatchboard, assign, rework, blocker, escalate, gateway-reply, submitreview.' -Code 'usage'
        }

        $wfAction = $remaining[0]
        $wfArgs = @($remaining | Select-Object -Skip 1)

        switch ($wfAction) {
            'dispatch' {
                $processQueue = $false
                $chatLimit = 20
                $processorLaunchId = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--process-queue' { $processQueue = $true; break }
                        '--processor-launch-id' { $processorLaunchId = $wfArgs[++$i]; break }
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
                            -TimeoutSec 300 `
                            -LaunchId $processorLaunchId
                        $resultOk = $true
                        if ($result -and ($result.PSObject.Properties.Name -contains 'ok')) {
                            $resultOk = [bool]$result.ok
                        }
                        Write-MconResult -Data ([ordered]@{
                                ok     = $resultOk
                                action = 'workflow.process_queue'
                                result = $result
                            })
                    }
                    catch {
                        Write-MconError -Message $_.Exception.Message -Code 'queue_error'
                    }
                }
                else {
                    try {
                        $dispatchResult = Invoke-MconDispatch -Config $agentConfig -ChatLimit $chatLimit
                    }
                    catch {
                        $errMsg = $_.Exception.Message
                        if ($errMsg -match 'connect(ion)? refused|No connection could be made|timed out|Failed to connect|Unable to connect|actively refused') {
                            Write-MconError -Message "API backend is not responding. Check that the API service is running." -Code 'api_down'
                        }
                        Write-MconError -Message $errMsg -Code 'dispatch_error'
                    }

                    $queued = 0
                    $skipped = 0
                    $cooldown = @()
                    if ($dispatchResult.act -eq $true) {
                        $dispatchStates = @(Get-MconHeartbeatDispatchStates -DispatchResult $dispatchResult)
                        foreach ($ds in $dispatchStates) {
                            $addResult = Add-MconHeartbeatQueueItem -WorkspacePath $agentConfig.workspace_path -InvocationAgent $invocationAgent -DispatchState $ds
                            switch ($addResult) {
                                'queued' {
                                    $queued++
                                }
                                'cooldown' {
                                    $skipped++
                                    $taskId = Get-MconHeartbeatQueueItemId -DispatchState $ds
                                    $cooldown += $taskId
                                }
                                default {
                                    $skipped++
                                }
                            }
                        }
                    }

                    $processingStart = Start-MconHeartbeatQueueProcessor -WorkspacePath $agentConfig.workspace_path -MconScriptPath $PSCommandPath

                    Write-MconResult -Data ([ordered]@{
                            ok       = $true
                            action   = 'workflow.dispatch'
                            dispatch = $dispatchResult
                            queue    = [ordered]@{
                                queued             = $queued
                                skipped            = $skipped
                                cooldown           = $cooldown
                                processing_started = [bool]($processingStart.confirmed_started)
                                processing         = $processingStart
                            }
                        })
                }
            }

            'dispatchboard' {
                $boardId = $null
                $delaySeconds = 60
                $chatLimit = 20
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--board' { $boardId = $wfArgs[++$i]; break }
                        '--delay' { $delaySeconds = [int]$wfArgs[++$i]; break }
                        '--chat-limit' { $chatLimit = [int]$wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $boardId) {
                    Write-MconError -Message '--board <BOARD_ID> is required.' -Code 'usage'
                }
                if ($boardId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid board ID format: $boardId" -Code 'validation'
                }

                $agentConfig = Resolve-MconKeybagAgent
                if (-not $agentConfig) {
                    Write-MconError -Message "No agent configuration found for current directory. Run from an agent workspace or set MCON_* env vars." -Code 'config_error'
                }

                $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
                $actionKey = 'workflow.dispatchboard'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                $dispatchConfig = [ordered]@{
                    base_url   = $agentConfig.base_url
                    auth_token = $agentConfig.auth_token
                    board_id   = $boardId
                }

                try {
                    $result = Invoke-MconDispatchBoard -Config $dispatchConfig -DelaySeconds $delaySeconds -ChatLimit $chatLimit
                    Write-MconResult -Data $result
                }
                catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -match 'connect(ion)? refused|No connection could be made|timed out|Failed to connect|Unable to connect|actively refused') {
                        Write-MconError -Message "API backend is not responding. Check that the API service is running." -Code 'api_down'
                    }
                    Write-MconError -Message $errMsg -Code 'dispatchboard_error'
                }
            }

            'assign' {
                $taskId = $null
                $workerAgentId = $null
                $workerWorkspacePath = $null
                $originSessionKey = $null
                $bundleOnly = $false
                $dryRun = $false
                $processDeferredSpawn = $false
                $payloadPath = $null
                $messageFile = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--worker' { $workerAgentId = $wfArgs[++$i]; break }
                        '--worker-workspace' { $workerWorkspacePath = $wfArgs[++$i]; break }
                        '--origin-session-key' { $originSessionKey = $wfArgs[++$i]; break }
                        '--bundle-only' { $bundleOnly = $true; break }
                        '--dry-run' { $dryRun = $true; break }
                        '--process-deferred-spawn' { $processDeferredSpawn = $true; break }
                        '--payload' { $payloadPath = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if ($processDeferredSpawn) {
                    if (-not $payloadPath) {
                        Write-MconError -Message '--payload <PATH> is required with --process-deferred-spawn.' -Code 'usage'
                    }

                    try {
                        $result = Invoke-MconDeferredAssignSpawn -PayloadPath $payloadPath
                        if ($result.ok) {
                            Write-MconResult -Data ([ordered]@{
                                    ok     = $true
                                    action = 'workflow.assign.deferred'
                                    result = $result
                                })
                            return
                        }
                        else {
                            Write-MconError -Message "$($result.phase): $($result.error)" -Code 'assign_error'
                        }
                    }
                    catch {
                        Write-MconError -Message $_.Exception.Message -Code 'assign_error'
                    }
                }

                # Handle --message-file for workflow commands (read message from file)
                if ($messageFile) {
                    if ($message) {
                        Write-MconError -Message 'Use either --message <TEXT> or --message-file <PATH>, not both.' -Code 'usage'
                    }
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message \"Message file not found: $messageFile\" -Code 'validation'
                    }
                    $message = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
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

                if (-not $originSessionKey) {
                    $originSessionKey = $env:MCON_ORIGIN_SESSION_KEY
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
                        Config           = $agentConfig
                        TaskId           = $taskId
                        WorkerAgentId    = $workerAgentId
                        OriginSessionKey = $originSessionKey
                        MconScriptPath   = $PSCommandPath
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
                    }
                    else {
                        Write-MconError -Message "$($result.phase): $($result.error)" -Code 'assign_error'
                    }
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'assign_error'
                }
            }

            'rework' {
                $taskId = $null
                $workerAgentId = $null
                $message = $null
                $messageFile = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--worker' { $workerAgentId = $wfArgs[++$i]; break }
                        '--message' { $message = $wfArgs[++$i]; break }
                        '--message-file' { $messageFile = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if ($messageFile) {
                    if ($message) {
                        Write-MconError -Message 'Use either --message <TEXT> or --message-file <PATH>, not both.' -Code 'usage'
                    }
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message "Message file not found: $messageFile" -Code 'validation'
                    }
                    $message = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
                }

                if (-not $taskId) {
                    Write-MconError -Message '--task <TASK_ID> is required.' -Code 'usage'
                }
                if (-not $workerAgentId) {
                    Write-MconError -Message '--worker <AGENT_ID> is required.' -Code 'usage'
                }
                if (-not $message) {
                    Write-MconError -Message '--message <TEXT> is required for rework.' -Code 'usage'
                }
                if ([string]::IsNullOrWhiteSpace($message)) {
                    Write-MconError -Message 'Message must not be empty.' -Code 'validation'
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
                $actionKey = 'workflow.rework'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                try {
                    $result = Invoke-MconRework -Config $agentConfig -TaskId $taskId -WorkerAgentId $workerAgentId -Message $message -MconScriptPath $PSCommandPath

                    if ($result.ok) {
                        Write-MconResult -Data ([ordered]@{
                                ok     = $true
                                action = 'workflow.rework'
                                result = $result
                            })
                    }
                    else {
                        Write-MconError -Message "$($result.phase): $($result.error)" -Code 'rework_error'
                    }
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'rework_error'
                }
            }

            'session-dispatch' {
                $processDispatch = $false
                $payloadPath = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--process' { $processDispatch = $true; break }
                        '--payload' { $payloadPath = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $processDispatch) {
                    Write-MconError -Message 'workflow session-dispatch is an internal command; use --process --payload <PATH>.' -Code 'usage'
                }
                if (-not $payloadPath) {
                    Write-MconError -Message '--payload <PATH> is required with workflow session-dispatch --process.' -Code 'usage'
                }

                try {
                    $result = Invoke-MconDeferredSessionDispatch -PayloadPath $payloadPath
                    if ($result.ok) {
                        Write-MconResult -Data ([ordered]@{
                                ok     = $true
                                action = 'workflow.session_dispatch.deferred'
                                result = $result
                            })
                        return
                    }

                    Write-MconError -Message "$($result.phase): $($result.error)" -Code 'session_dispatch_error'
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'session_dispatch_error'
                }
            }

            'blocker' {
                $taskId = $null
                $message = $null
                $messageFile = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--message' { $message = $wfArgs[++$i]; break }
                        '--message-file' { $messageFile = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                # Handle --message-file for workflow commands (read message from file)
                if ($messageFile) {
                    if ($message) {
                        Write-MconError -Message 'Use either --message <TEXT> or --message-file <PATH>, not both.' -Code 'usage'
                    }
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message \"Message file not found: $messageFile\" -Code 'validation'
                    }
                    $message = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
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
                    }
                    else {
                        Write-MconError -Message "$($result.message)" -Code $result.code
                    }
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'blocker_error'
                }
            }

            'escalate' {
                $taskId = $null
                $message = $null
                $messageFile = $null
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
                        '--message-file' { $messageFile = $wfArgs[++$i]; break }
                        '--secret-key' { $secretKey = $wfArgs[++$i]; break }
                        '--target-agent' { $targetAgentId = $wfArgs[++$i]; break }
                        '--target-agent-name' { $targetAgentName = $wfArgs[++$i]; break }
                        '--channel' { $preferredChannel = $wfArgs[++$i]; break }
                        '--correlation-id' { $correlationId = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                # Handle --message-file for workflow escalate (read message from file)
                if ($messageFile) {
                    if ($message) {
                        Write-MconError -Message 'Use either --message <TEXT> or --message-file <PATH>, not both.' -Code 'usage'
                    }
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message \"Message file not found: $messageFile\" -Code 'validation'
                    }
                    $message = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
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
                    }
                    else {
                        Write-MconError -Message "$($result.message)" -Code $result.code
                    }
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'escalate_error'
                }
            }

            'gateway-reply' {
                $boardId = $null
                $taskId = $null
                $message = $null
                $messageFile = $null
                $correlationId = $null
                $replyKind = 'user'
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--board' { $boardId = $wfArgs[++$i]; break }
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--message' { $message = $wfArgs[++$i]; break }
                        '--message-file' { $messageFile = $wfArgs[++$i]; break }
                        '--correlation-id' { $correlationId = $wfArgs[++$i]; break }
                        '--secret-reply' { $replyKind = 'secret'; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $boardId) {
                    Write-MconError -Message '--board <BOARD_ID> is required.' -Code 'usage'
                }
                if ($boardId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid board ID format: $boardId" -Code 'validation'
                }
                if ($taskId -and $taskId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid task ID format: $taskId" -Code 'validation'
                }
                if ($message -and $messageFile) {
                    Write-MconError -Message 'Use either --message or --message-file, not both.' -Code 'usage'
                }
                if ($messageFile) {
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message "Message file not found: $messageFile" -Code 'validation'
                    }
                    $message = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
                }
                if (-not $message) {
                    Write-MconError -Message '--message <TEXT> or --message-file <PATH> is required.' -Code 'usage'
                }
                if ([string]::IsNullOrWhiteSpace($message)) {
                    Write-MconError -Message 'Message must not be empty.' -Code 'validation'
                }

                $agentConfig = Resolve-MconKeybagAgent
                if (-not $agentConfig) {
                    Write-MconError -Message "No agent configuration found for current directory. Run from an agent workspace or set MCON_* env vars." -Code 'config_error'
                }

                $role = Resolve-MconExecutionRole -Wsp $agentConfig.wsp -WorkspacePath $agentConfig.workspace_path
                $actionKey = 'workflow.gateway-reply'
                if (-not (Test-MconPermission -Action $actionKey -Role $role)) {
                    $msg = Get-MconDeniedMessage -Action $actionKey -Role $role
                    Write-MconError -Message $msg -Code 'forbidden'
                }

                try {
                    $result = Invoke-MconGatewayReply `
                        -Config $agentConfig `
                        -BoardId $boardId `
                        -Message $message `
                        -TaskId $taskId `
                        -CorrelationId $correlationId `
                        -ReplyKind $replyKind

                    if ($result.ok) {
                        Write-MconResult -Data ([ordered]@{
                                ok     = $true
                                action = 'workflow.gateway-reply'
                                result = $result
                            })
                    }
                    else {
                        Write-MconError -Message "$($result.message)" -Code $result.code
                    }
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'gateway_reply_error'
                }
            }

            'submitreview' {
                $taskId = $null
                $message = $null
                $messageFile = $null
                $i = 0
                while ($i -lt $wfArgs.Count) {
                    switch ($wfArgs[$i]) {
                        '--task' { $taskId = $wfArgs[++$i]; break }
                        '--message' { $message = $wfArgs[++$i]; break }
                        '--message-file' { $messageFile = $wfArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($wfArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                # Handle --message-file for workflow commands (read message from file)
                if ($messageFile) {
                    if ($message) {
                        Write-MconError -Message 'Use either --message <TEXT> or --message-file <PATH>, not both.' -Code 'usage'
                    }
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message \"Message file not found: $messageFile\" -Code 'validation'
                    }
                    $message = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
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
                    }
                    else {
                        Write-MconError -Message "$($result.message)" -Code $result.code
                    }
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'submitreview_error'
                }
            }

            default {
                Write-MconError -Message "Unknown workflow action: $wfAction. Valid: dispatch, dispatchboard, assign, rework, blocker, escalate, gateway-reply, submitreview." -Code 'usage'
            }
        }
    }

    'verify' {
        if ($remaining.Count -lt 1) {
            Write-MconError -Message 'Usage: mcon verify run --task <TASK_ID>' -Code 'usage'
        }

        $verifyAction = $remaining[0]
        $verifyArgs = @($remaining | Select-Object -Skip 1)
        $messageFile = $null

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

                # Handle --message-file for workflow commands (read message from file)
                if ($messageFile) {
                    if ($message) {
                        Write-MconError -Message 'Use either --message <TEXT> or --message-file <PATH>, not both.' -Code 'usage'
                    }
                    if (-not (Test-Path -LiteralPath $messageFile)) {
                        Write-MconError -Message \"Message file not found: $messageFile\" -Code 'validation'
                    }
                    $message = Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8
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
                    $result = Invoke-MconVerifyRun -Config $agentConfig -TaskId $taskId -MconScriptPath $PSCommandPath
                    Write-MconResult -Data ([ordered]@{
                            ok     = $true
                            action = 'verify.run'
                            result = $result
                        })
                }
                catch {
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
            Write-MconError -Message 'Usage: mcon admin <action>. Actions: gettokens, decrypt-keybag, sync-allowagents, templatedist, cron.' -Code 'usage'
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
                    Write-MconError -Message $_.Exception.Message -Code (Get-MconErrorCodeFromException -Exception $_.Exception)
                }
            }
            'decrypt-keybag' {
                $inputPath = '~/.agent-tokens.json.enc'
                $outputPath = '~/.agent-tokens.json'
                $keyPath = '~/.mcon-secret.key'

                $i = 0
                while ($i -lt $adminArgs.Count) {
                    switch ($adminArgs[$i]) {
                        '--input' { $inputPath = $adminArgs[++$i]; break }
                        '--output' { $outputPath = $adminArgs[++$i]; break }
                        '--key' { $keyPath = $adminArgs[++$i]; break }
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
            'sync-allowagents' {
                try {
                    Sync-MconAllowAgents
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'sync_error'
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
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'templatedist_error'
                }
            }
            'cron' {
                $cronBoardId = $null
                $cronCadence = $null
                $cronDryRun = $false
                $cronCrontabDir = '/etc/cron.d'

                $i = 0
                while ($i -lt $adminArgs.Count) {
                    switch ($adminArgs[$i]) {
                        '--board-id' { $cronBoardId = $adminArgs[++$i]; break }
                        '--cadence-minutes' { $cronCadence = $adminArgs[++$i]; break }
                        '--dry-run' { $cronDryRun = $true; break }
                        '--crontab-dir' { $cronCrontabDir = $adminArgs[++$i]; break }
                        default { Write-MconError -Message "Unknown flag: $($adminArgs[$i])" -Code 'usage' }
                    }
                    $i++
                }

                if (-not $cronBoardId) {
                    Write-MconError -Message '--board-id <BOARD_ID> is required.' -Code 'usage'
                }
                if ($cronBoardId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-MconError -Message "Invalid board ID format: $cronBoardId" -Code 'validation'
                }
                if ($null -eq $cronCadence) {
                    Write-MconError -Message '--cadence-minutes <INT> is required.' -Code 'usage'
                }
                try {
                    $cronCadence = [int]$cronCadence
                }
                catch {
                    Write-MconError -Message "--cadence-minutes must be an integer. Got: $cronCadence" -Code 'validation'
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
                    $cronParams = @{
                        BaseUrl        = 'http://localhost:8002'
                        AuthToken      = $localAuthToken
                        BoardId        = $cronBoardId
                        CadenceMinutes = $cronCadence
                        CrontabDir     = $cronCrontabDir
                    }
                    if ($cronDryRun) { $cronParams.DryRun = $true }

                    $result = Invoke-MconAdminCron @cronParams
                    Write-MconResult -Data $result
                }
                catch {
                    Write-MconError -Message $_.Exception.Message -Code 'cron_error'
                }
            }
            default {
                Write-MconError -Message "Unknown admin action: $adminAction. Valid: gettokens, decrypt-keybag, templatedist, cron." -Code 'usage'
            }
        }
    }

    default {
        Write-MconError -Message "Unknown subcommand: $subcommand. Run 'mcon help' for usage." -Code 'usage'
    }
}
