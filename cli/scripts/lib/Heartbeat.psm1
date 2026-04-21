function Get-MconOpenClawGatewayConfig {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $openClawRoot = Split-Path -Path $WorkspacePath -Parent
    $configPath = Join-Path $openClawRoot 'openclaw.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "OpenClaw config not found: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 50
    $port = $config.gateway.port
    $token = $config.gateway.auth.token
    $chatEnabled = $config.gateway.http.endpoints.chatCompletions.enabled

    if (-not $port) { throw "Gateway port missing in $configPath" }
    if (-not $token) { throw "Gateway auth token missing in $configPath" }
    if (-not $chatEnabled) { throw "Gateway chat completions endpoint is disabled in $configPath" }

    return [pscustomobject]@{
        port  = [int]$port
        token = [string]$token
    }
}

function Get-MconTaskSessionKey {
    param(
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)]$DispatchState
    )

    $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
    if ($firstTask -and $firstTask.id) {
        return "agent:${InvocationAgent}:task:$($firstTask.id)"
    }

    return "agent:${InvocationAgent}:dispatch-run:$([guid]::NewGuid().Guid)"
}

function New-MconLeadClosureDirective {
    param(
        [Parameter(Mandatory)]$TaskRefs
    )

    $doneTaskRefs = @($TaskRefs | Where-Object { $_.status -eq 'done' })
    if ($doneTaskRefs.Count -eq 0) {
        return $null
    }

    $taskLines = @()
    foreach ($taskRef in $doneTaskRefs) {
        $taskLines += "- Task $($taskRef.id): $($taskRef.title)"
        $taskLines += "  task context: [taskData.json]($($taskRef.taskDataPath))"
        $taskLines += "  deliverables: [deliverables/]($($taskRef.deliverablesDir))"
        $taskLines += "  evidence: [evidence/]($($taskRef.evidenceDir))"
    }

    return (@'
## TASK-SPECIFIC CLOSURE DIRECTIVE

The following task(s) are already in `done` and require post-completion follow-through in this turn:
{0}

Before ending the turn, execute this closure protocol for each completed task:
1. Scan for implied follow-up work.
   - Read the completed task's description, comments, and evidence.
   - Ask whether the completion creates, enables, or necessitates any new board task.
   - If yes, create the follow-up task(s) before replying.
2. Check dependent tasks.
   - For each task that lists the completed task in `depends_on_task_ids`, add a dependency-resolution notice.
   - If the dependent task is now unblocked and the next step is clear, prepare it for reassessment.
3. Ingest reusable patterns.
   - Capture reusable process, script, decision, or operational improvements in the proper durable surface.
   - Use the wiki for broadly reusable concepts or syntheses, and record durable updates in `MEMORY.md` where appropriate.
4. Capture self-improvement items.
   - Log mistakes, better approaches, or systemic friction in the appropriate learning surface.
   - Promote durable behavior to `SOUL.md`, workflow rules to `AGENTS.md`, and tool rules to `TOOLS.md` when justified.
5. Update the project ledger when the task is project-tagged.
   - Run `scripts/update-project-ledger.ps1 -ProjectTag <tag>`.
   - Verify `active_krs`, `current_phase`, and `next_recommended_task` against board reality.
6. Post a concise factual closure summary comment.
   - Include deliverables, follow-up tasks, wiki ingestion, and any remaining risk or open question.

Keep the control-plane boundary intact: you may create follow-up tasks or leave breadcrumbs here, but defer any fresh assignment or work-start decision to the next gated heartbeat authorization.
'@ -f ($taskLines -join "`n"))
}

function New-MconHeartbeatPrompt {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)]$DispatchState,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$SessionKey
    )

    $tasks = @($DispatchState.tasks | Where-Object { $_ -and $_.id })
    $taskRefs = @()
    foreach ($task in $tasks) {
        $taskDataPath = $null
        if ($task.PSObject.Properties.Name -contains 'task_data_path' -and $task.task_data_path) {
            $taskDataPath = [string]$task.task_data_path
        } else {
            $taskDataPath = Join-Path (Join-Path (Join-Path $WorkspacePath 'tasks') $task.id) 'taskData.json'
        }

        $taskDir = Split-Path -Path $taskDataPath -Parent
        $deliverablesDir = if ($task.PSObject.Properties.Name -contains 'deliverables_directory' -and $task.deliverables_directory) {
            [string]$task.deliverables_directory
        } else {
            Join-Path $taskDir 'deliverables'
        }
        $evidenceDir = if ($task.PSObject.Properties.Name -contains 'evidence_directory' -and $task.evidence_directory) {
            [string]$task.evidence_directory
        } else {
            Join-Path $taskDir 'evidence'
        }
        $resolvedTaskDir = if ($task.PSObject.Properties.Name -contains 'task_directory' -and $task.task_directory) {
            [string]$task.task_directory
        } else {
            $taskDir
        }

        $taskRefs += [ordered]@{
            id              = $task.id
            title           = if ($task.PSObject.Properties.Name -contains 'title') { [string]$task.title } else { '' }
            status          = $task.status
            taskDataPath    = $taskDataPath
            taskDir         = $resolvedTaskDir
            deliverablesDir = $deliverablesDir
            evidenceDir     = $evidenceDir
        }
    }

    $assignmentAuthorized = $false
    $assignmentTaskId = $null
    $inboxTasks = @($tasks | Where-Object { $_.status -eq 'inbox' })
    $reasonText = ''
    if ($DispatchState.PSObject.Properties.Name -contains 'reason' -and $DispatchState.reason) {
        $reasonText = [string]$DispatchState.reason
    }
    if ($inboxTasks.Count -eq 1 -and $reasonText -match 'inbox') {
        $assignmentAuthorized = $true
        $assignmentTaskId = [string]$inboxTasks[0].id
    }

    $gatedHeartbeatPath = Join-Path $WorkspacePath 'GATED-HEARTBEAT.md'
    if (-not (Test-Path -LiteralPath $gatedHeartbeatPath)) {
        throw "GATED-HEARTBEAT.md not found at $gatedHeartbeatPath"
    }

    $taskLinks = @()
    foreach ($taskRef in $taskRefs) {
        $taskLinks += "- Task $($taskRef.id) ($($taskRef.status)): [taskData.json]($($taskRef.taskDataPath))"
        $taskLinks += "  deliverables: [deliverables/]($($taskRef.deliverablesDir))"
        $taskLinks += "  evidence: [evidence/]($($taskRef.evidenceDir))"
    }

    $sections = @()
    $sections += @"
# HEARTBEAT
Board dispatch summary:
- act: $($DispatchState.act)
- reason: $($DispatchState.reason)
- boardId: $($DispatchState.boardId)
- agentId: $($DispatchState.agentId)
- sessionKey: $SessionKey
- task count: $($tasks.Count)
- ASSIGNMENT_AUTHORIZED: $($assignmentAuthorized.ToString().ToLowerInvariant())
- Use the sessionKey above directly for any gated assignment. Do not search for it elsewhere.
"@
    if ($assignmentAuthorized -and $assignmentTaskId) {
        $sections += "- ASSIGNMENT_TASK_ID: $assignmentTaskId"
    }
    $sections += @"

Read these task context files first:
$($taskLinks -join "`n")

AUTH_TOKEN=$AuthToken

"@
    $closureDirective = New-MconLeadClosureDirective -TaskRefs $taskRefs
    if ($closureDirective) {
        $sections += $closureDirective
        $sections += ""
    }
    $sections += (Get-Content -LiteralPath $gatedHeartbeatPath -Raw)
    return ($sections -join "`n")
}

function Invoke-MconOpenClawGatewayChat {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$SessionKey,
        [int]$TimeoutSec = 120
    )

    $gateway = Get-MconOpenClawGatewayConfig -WorkspacePath $WorkspacePath
    $uri = "http://127.0.0.1:$($gateway.port)/v1/chat/completions"
    $headers = @{
        Authorization         = "Bearer $($gateway.token)"
        'x-openclaw-session-key' = $SessionKey
    }
    $body = @{
        model    = "openclaw/$InvocationAgent"
        messages = @(
            @{
                role    = 'user'
                content = $Message
            }
        )
    } | ConvertTo-Json -Depth 10

    return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
}

function Invoke-MconOpenClawAgentSession {
    param(
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)][string]$SessionKey,
        [Parameter(Mandatory)][string]$Message,
        [int]$TimeoutSec = 300
    )

    $agentOutput = & openclaw agent --agent $InvocationAgent --session-id $SessionKey --message $Message --json --timeout $TimeoutSec --thinking off 2>&1
    return [ordered]@{
        exit_code = $LASTEXITCODE
        output    = ($agentOutput -join "`n")
    }
}

function Invoke-MconHeartbeatAgent {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)]$DispatchState,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$SessionKey,
        [int]$TimeoutSec = 120
    )

    $prompt = New-MconHeartbeatPrompt -WorkspacePath $WorkspacePath -DispatchState $DispatchState -AuthToken $AuthToken -SessionKey $SessionKey
    $response = Invoke-MconOpenClawGatewayChat `
        -WorkspacePath $WorkspacePath `
        -InvocationAgent $InvocationAgent `
        -Message $prompt `
        -SessionKey $SessionKey `
        -TimeoutSec $TimeoutSec

    $response | ConvertTo-Json -Depth 50
}

function Invoke-MconVerifierAgent {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)]$DispatchState,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$SessionKey,
        [int]$TimeoutSec = 300
    )

    $prompt = New-MconVerifierPrompt -WorkspacePath $WorkspacePath -DispatchState $DispatchState -AuthToken $AuthToken -SessionKey $SessionKey
    $result = Invoke-MconOpenClawAgentSession `
        -InvocationAgent $InvocationAgent `
        -SessionKey $SessionKey `
        -Message $prompt `
        -TimeoutSec $TimeoutSec

    return [ordered]@{
        exit_code      = $result.exit_code
        output         = $result.output
        command_output = $result.output
    }
}

function Get-MconHeartbeatQueuePaths {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $workflowPath = Join-Path $WorkspacePath '.openclaw/workflows'
    $queueRoot = Join-Path $workflowPath 'mc-board-heartbeat-queue'
    return [pscustomobject]@{
        workflow   = $workflowPath
        root       = $queueRoot
        pending    = Join-Path $queueRoot 'pending'
        processing = Join-Path $queueRoot 'processing'
        failed     = Join-Path $queueRoot 'failed'
        retired    = Join-Path $queueRoot 'retired'
        lock       = Join-Path $queueRoot 'processing.lock.json'
        stdoutLog  = Join-Path $queueRoot 'processor.stdout.log'
        stderrLog  = Join-Path $queueRoot 'processor.stderr.log'
    }
}

function Initialize-MconHeartbeatQueue {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $paths = Get-MconHeartbeatQueuePaths -WorkspacePath $WorkspacePath
    foreach ($dir in @($paths.workflow, $paths.root, $paths.pending, $paths.processing, $paths.failed, $paths.retired)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    return $paths
}

function Test-MconHeartbeatProcessAlive {
    param([int]$ProcessId)

    if (-not $ProcessId) { return $false }
    try {
        Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Restore-MconHeartbeatProcessingQueue {
    param(
        [Parameter(Mandatory)]$QueuePaths
    )

    $processingItems = @(
        Get-ChildItem -LiteralPath $QueuePaths.processing -Filter '*.json' -File -ErrorAction SilentlyContinue
    )

    foreach ($item in $processingItems) {
        $pendingPath = Join-Path $QueuePaths.pending $item.Name
        if (Test-Path -LiteralPath $pendingPath) {
            Remove-Item -LiteralPath $item.FullName -Force
            continue
        }
        Move-Item -LiteralPath $item.FullName -Destination $pendingPath -Force
    }
}

function Clear-MconHeartbeatStuckProcessingItems {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        [int]$MaxProcessingMinutes = 10,
        [string]$LogPath = $null
    )

    $cutoffTime = (Get-Date).AddMinutes(-$MaxProcessingMinutes)
    $stuckItems = @(
        Get-ChildItem -LiteralPath $QueuePaths.processing -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoffTime }
    )

    foreach ($item in $stuckItems) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $failedName = "$($item.BaseName)-stale-$ts.json"
        $failedPath = Join-Path $QueuePaths.failed $failedName
        Write-MconQueueLog -Path $LogPath -Message "moving stuck processing item to failed: $($item.Name)"
        Move-Item -LiteralPath $item.FullName -Destination $failedPath -Force
    }

    return $stuckItems.Count
}

function Get-MconHeartbeatQueueLockState {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $paths = Initialize-MconHeartbeatQueue -WorkspacePath $WorkspacePath
    if (-not (Test-Path -LiteralPath $paths.lock)) {
        return [pscustomobject]@{
            active = $false
            paths  = $paths
            lock   = $null
        }
    }

    $lockData = $null
    try {
        $lockData = Get-Content -LiteralPath $paths.lock -Raw | ConvertFrom-Json -Depth 10
    } catch {
        Remove-Item -LiteralPath $paths.lock -Force
        Restore-MconHeartbeatProcessingQueue -QueuePaths $paths
        return [pscustomobject]@{
            active = $false
            paths  = $paths
            lock   = $null
        }
    }

    $lockPid = $null
    if ($lockData -and $lockData.PSObject.Properties.Name -contains 'pid' -and $lockData.pid) {
        $lockPid = [int]$lockData.pid
    }

    if ($lockPid -and (Test-MconHeartbeatProcessAlive -Pid $lockPid)) {
        return [pscustomobject]@{
            active = $true
            paths  = $paths
            lock   = $lockData
        }
    }

    Remove-Item -LiteralPath $paths.lock -Force
    Restore-MconHeartbeatProcessingQueue -QueuePaths $paths
    return [pscustomobject]@{
        active = $false
        paths  = $paths
        lock   = $lockData
    }
}

function Test-MconHeartbeatQueueProcessing {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $state = Get-MconHeartbeatQueueLockState -WorkspacePath $WorkspacePath
    return [bool]$state.active
}

function Request-MconHeartbeatQueueLock {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $state = Get-MconHeartbeatQueueLockState -WorkspacePath $WorkspacePath
    if ($state.active) {
        return [pscustomobject]@{
            acquired = $false
            paths    = $state.paths
        }
    }

    $lockPayload = [ordered]@{
        pid        = $PID
        started_at = (Get-Date).ToUniversalTime().ToString('o')
        host       = [System.Net.Dns]::GetHostName()
    }

    try {
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes(($lockPayload | ConvertTo-Json -Depth 10))
        $stream = [System.IO.File]::Open(
            $state.paths.lock,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $stream.Write($lockBytes, 0, $lockBytes.Length)
        } finally {
            $stream.Dispose()
        }

        return [pscustomobject]@{
            acquired = $true
            paths    = $state.paths
        }
    } catch [System.IO.IOException] {
        return [pscustomobject]@{
            acquired = $false
            paths    = $state.paths
        }
    }
}

function Unlock-MconHeartbeatQueueLock {
    param(
        [Parameter(Mandatory)]$QueuePaths
    )

    if (Test-Path -LiteralPath $QueuePaths.lock) {
        Remove-Item -LiteralPath $QueuePaths.lock -Force
    }
}

function Get-MconHeartbeatQueueItemId {
    param(
        [Parameter(Mandatory)]$DispatchState
    )

    $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
    if ($firstTask -and $firstTask.id) {
        return [string]$firstTask.id
    }

    $reason = 'dispatch'
    if ($DispatchState.PSObject.Properties.Name -contains 'reason' -and $DispatchState.reason) {
        $reason = [string]$DispatchState.reason
    }

    $safeReason = ($reason -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if (-not $safeReason) { $safeReason = 'dispatch' }

    return "dispatch-$safeReason"
}

function Write-MconQueueLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    $line = "[{0}] {1}" -f (Get-Date).ToString('o'), $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Write-MconQueueOutput {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    foreach ($line in @($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        Write-MconQueueLog -Path $Path -Message "$Prefix $line"
    }
}

function New-MconVerifierPrompt {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)]$DispatchState,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$SessionKey
    )

    $tasks = @($DispatchState.tasks | Where-Object { $_ -and $_.id })
    if ($tasks.Count -eq 0) {
        throw "Verifier prompt requires at least one task"
    }

    $gatedHeartbeatPath = Join-Path $WorkspacePath 'GATED-HEARTBEAT.md'
    if (-not (Test-Path -LiteralPath $gatedHeartbeatPath)) {
        throw "GATED-HEARTBEAT.md not found at $gatedHeartbeatPath"
    }

    $task = $tasks[0]
    $taskLines = @()
    foreach ($taskRef in $tasks) {
        $taskLines += "- Task $($taskRef.id) ($($taskRef.status)): [taskData.json]($($taskRef.task_data_path))"
        $taskLines += "  deliverables: [deliverables/]($($taskRef.deliverables_directory))"
        $taskLines += "  evidence: [evidence/]($($taskRef.evidence_directory))"
    }

    $sections = @()
    $sections += @"
# VERIFIER
Board dispatch summary:
- act: $($DispatchState.act)
- reason: $($DispatchState.reason)
- boardId: $($DispatchState.boardId)
- agentId: $($DispatchState.agentId)
- sessionKey: $SessionKey
- task count: $($tasks.Count)
- task_id: $($task.id)
- task_title: $($task.title)
- task_status: $($task.status)

Read these task context files first:
$($taskLines -join "`n")

AUTH_TOKEN=$AuthToken

"@
    $sections += (Get-Content -LiteralPath $gatedHeartbeatPath -Raw)
    return ($sections -join "`n")
}

function Add-MconHeartbeatQueueItem {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)]$DispatchState,
        [int]$MaxFailures = 3
    )

    $paths = Initialize-MconHeartbeatQueue -WorkspacePath $WorkspacePath
    $queueItemId = Get-MconHeartbeatQueueItemId -DispatchState $DispatchState
    $pendingPath = Join-Path $paths.pending "$queueItemId.json"
    $processingPath = Join-Path $paths.processing "$queueItemId.json"

    if ((Test-Path -LiteralPath $pendingPath)) {
        Write-MconQueueLog -Path $paths.stdoutLog -Message "SKIP already_pending $queueItemId"
        return 'already_pending'
    }

    if ((Test-Path -LiteralPath $processingPath)) {
        Write-MconQueueLog -Path $paths.stdoutLog -Message "SKIP already_processing $queueItemId"
        return 'already_processing'
    }

    $failedFiles = @(Get-ChildItem -LiteralPath $paths.failed -Filter "$queueItemId*.json" -File -ErrorAction SilentlyContinue)
    $failureCount = $failedFiles.Count

    if ($failureCount -ge $MaxFailures) {
        $retiredPath = Join-Path $paths.retired "$queueItemId.json"
        if (-not (Test-Path -LiteralPath $retiredPath)) {
            $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
            $failureReasons = @()
            foreach ($ff in ($failedFiles | Sort-Object LastWriteTime | Select-Object -Last 3)) {
                try {
                    $fd = Get-Content -LiteralPath $ff.FullName -Raw | ConvertFrom-Json -Depth 10
                    $failureReasons += if ($fd.error) { $fd.error } elseif ($fd.command_output) { $fd.command_output } elseif ($fd.output) { $fd.output } else { $null }
                } catch {}
            }
            $retiredRecord = [ordered]@{
                queue_item_id    = $queueItemId
                retired_at       = (Get-Date).ToUniversalTime().ToString('o')
                total_failures   = $failureCount
                last_errors      = $failureReasons
                invocation_agent = $InvocationAgent
                task_id          = if ($firstTask -and $firstTask.id) { $firstTask.id } else { $null }
                task_title       = if ($firstTask -and $firstTask.title) { $firstTask.title } else { $null }
                task_status      = if ($firstTask -and $firstTask.status) { $firstTask.status } else { $null }
            }
            $retiredRecord | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $retiredPath -Encoding UTF8
            Write-MconQueueLog -Path $paths.stdoutLog -Message "RETIRED $($queueItemId): $failureCount failures, task=$($retiredRecord.task_id) ($($retiredRecord.task_title))"
        }
        Write-MconQueueLog -Path $paths.stdoutLog -Message "SKIP retired $queueItemId"
        return 'retired'
    }

    $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
    $queueItem = [ordered]@{
        queue_item_id   = $queueItemId
        enqueued_at     = (Get-Date).ToUniversalTime().ToString('o')
        invocation_agent = $InvocationAgent
        session_key     = Get-MconTaskSessionKey -InvocationAgent $InvocationAgent -DispatchState $DispatchState
        dispatch_state  = $DispatchState
    }

    if ($firstTask -and $firstTask.id) {
        $queueItem.task_id = $firstTask.id
        $queueItem.task_status = $firstTask.status
    }

    $queueItem | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $pendingPath -Encoding UTF8
    Write-MconQueueLog -Path $paths.stdoutLog -Message "QUEUED $queueItemId dispatch_type=$($DispatchState.dispatch_type) session_key=$($queueItem.session_key)"
    return 'queued'
}

function Start-MconHeartbeatQueueProcessor {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$MconScriptPath
    )

    $state = Get-MconHeartbeatQueueLockState -WorkspacePath $WorkspacePath
    if ($state.active) { return $false }

    $pendingItems = @(
        Get-ChildItem -LiteralPath $state.paths.pending -Filter '*.json' -File -ErrorAction SilentlyContinue
    )
    if ($pendingItems.Count -eq 0) { return $false }

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

    Start-Process `
        -FilePath $pwshPath `
        -ArgumentList @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $MconScriptPath, 'workflow', 'dispatch', '--process-queue') `
        -WorkingDirectory $WorkspacePath `
        -RedirectStandardOutput $state.paths.stdoutLog `
        -RedirectStandardError $state.paths.stderrLog | Out-Null

    return $true
}

function Get-MconHeartbeatDispatchStates {
    param(
        [Parameter(Mandatory)]$DispatchResult
    )

    $activeTasks = @($DispatchResult.tasks | Where-Object { $_ -and $_.id })
    if ($activeTasks.Count -eq 0) {
        return @($DispatchResult)
    }

    $dispatchStates = @()
    foreach ($task in $activeTasks) {
        $taskDispatchState = [ordered]@{
            act       = $DispatchResult.act
            reason    = $DispatchResult.reason
            dispatch_type = if ($DispatchResult.agentRole -eq 'verifier') { 'verify' } else { 'heartbeat' }
            agentRole = $DispatchResult.agentRole
            boardId   = $DispatchResult.boardId
            agentId   = $DispatchResult.agentId
            summary   = $DispatchResult.summary
            tasks     = @($task)
        }
        $dispatchStates += [pscustomobject]$taskDispatchState
    }

    return $dispatchStates
}

function Invoke-MconRecoveryPrompt {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)]$DispatchState,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$BoardId,
        [int]$TimeoutSec = 60
    )

    $taskId = $DispatchState.task_id
    $recoveryAttempt = $DispatchState.recovery_attempt
    $stallReason = $DispatchState.stall_reason
    $subagentSessionKey = $DispatchState.subagent_session_key
    $subagentAgentId = $DispatchState.subagent_agent_id
    $taskDataPath = $DispatchState.task_data_path

    if (-not $taskId) { throw "Missing task_id in recovery dispatch_state" }
    if (-not $subagentSessionKey) { throw "Missing subagent_session_key in recovery dispatch_state" }
    if (-not $subagentAgentId) { throw "Missing subagent_agent_id in recovery dispatch_state" }
    if (-not $taskDataPath) { throw "Missing task_data_path in recovery dispatch_state" }

    if (-not (Test-Path -LiteralPath $taskDataPath)) {
        throw "taskData.json not found at $taskDataPath"
    }
    $taskData = Get-Content -LiteralPath $taskDataPath -Raw | ConvertFrom-Json -Depth 50

    $progress = if ($taskData.task.PSObject.Properties.Name -contains 'progress') { $taskData.task.progress } else { 'unknown' }
    $lastAction = if ($taskData.task.PSObject.Properties.Name -contains 'last_action') { $taskData.task.last_action } else { 'unknown' }
    $errors = @()
    if ($taskData.task.PSObject.Properties.Name -contains 'evidence' -and $taskData.task.evidence) {
        $errors = @($taskData.task.evidence | Where-Object { $_.type -eq 'error' } | Select-Object -ExpandProperty message -First 3)
    }
    $errorSummary = if ($errors) { ($errors -join '; ') } else { 'none' }

    $recoveryPrompt = @"
[RECOVERY TURN #$recoveryAttempt] — Stall detected on task $taskId.

Condition: $stallReason
Last known state:
- Progress: $progress
- Recent action: $lastAction
- Recent errors: $errorSummary

**Your next step must be one of:**
1. REQUEST_CLARIFICATION — ask ONE specific question to unblock (max 1 question, max 200 chars)
2. PROPOSE_RETRY — describe exactly what you will retry and how you'll avoid the same error (max 150 words)
3. SIGNAL_ESCALATION — state why you cannot proceed and what the lead must do (max 100 words)

Respond in this exact format:
```json
{
  "recovery_action": "REQUEST_CLARIFICATION|PROPOSE_RETRY|SIGNAL_ESCALATION",
  "next_step_description": "<concise description>",
  "required_input": "<what you need from lead, or 'none'>",
  "estimated_completion_cycles": <positive_integer>
}
```

Do not add commentary outside this structure. If you cannot comply, respond with SIGNAL_ESCALATION.
"@

    Write-Host "[{0}] Sending recovery prompt to subagent session (key: {1}, agent: {2})" -f (Get-Date).ToString('o'), $subagentSessionKey, $subagentAgentId

    $gateway = Get-MconOpenClawGatewayConfig -WorkspacePath $WorkspacePath
    $uri = "http://127.0.0.1:$($gateway.port)/v1/chat/completions"
    $headers = @{
        Authorization            = "Bearer $($gateway.token)"
        'x-openclaw-session-key' = $subagentSessionKey
    }
    $body = @{
        model       = "openclaw/$subagentAgentId"
        messages    = @(@{ role = 'user'; content = $recoveryPrompt })
        temperature = 0.3
        max_tokens  = 500
    } | ConvertTo-Json -Depth 10

    $startTime = Get-Date
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
    $elapsedMs = ((Get-Date) - $startTime).TotalMilliseconds

    $rawReply = $response.choices[0].message.content
    Write-Host "[{0}] Subagent reply received ({1}ms)" -f (Get-Date).ToString('o'), [math]::Round($elapsedMs)

    $parsedReply = $null
    $parseSuccess = $false
    try {
        $parsedReply = $rawReply | ConvertFrom-Json -Depth 10
        $requiredFields = @('recovery_action', 'next_step_description', 'required_input', 'estimated_completion_cycles')
        foreach ($field in $requiredFields) {
            if (-not $parsedReply.PSObject.Properties.Name -contains $field) {
                throw "Missing required field: $field"
            }
        }
        if ($parsedReply.recovery_action -notin @('REQUEST_CLARIFICATION', 'PROPOSE_RETRY', 'SIGNAL_ESCALATION')) {
            throw "Invalid recovery_action: $($parsedReply.recovery_action)"
        }
        $parseSuccess = $true
    } catch {
        $parseSuccess = $false
        $parsedReply = $null
        Write-Warning "Failed to parse subagent reply as valid JSON: $_"
    }

    $taskDir = Split-Path -Path $taskDataPath -Parent
    $evidenceDir = Join-Path $taskDir 'evidence'
    if (-not (Test-Path -LiteralPath $evidenceDir)) {
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $guid = [guid]::NewGuid().Guid
    $evidenceFile = Join-Path $evidenceDir "recovery-turn-$recoveryAttempt-$guid.json"

    $evidence = [ordered]@{
        timestamp           = (Get-Date).ToUniversalTime().ToString('o')
        task_id             = $taskId
        subagent_session_key = $subagentSessionKey
        subagent_agent_id   = $subagentAgentId
        recovery_attempt    = $recoveryAttempt
        stall_reason        = $stallReason
        prompt_sent         = $recoveryPrompt
        raw_reply           = $rawReply
        parsed_successfully = $parseSuccess
        parsed_reply        = if ($parseSuccess) { $parsedReply } else { $null }
        escalation_triggered = $false
        gateway_response_ms = [math]::Round($elapsedMs)
    }

    $evidence | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $evidenceFile -Encoding UTF8
    Write-Host "[{0}] Evidence written: {1}" -f (Get-Date).ToString('o'), $evidenceFile

    $commentBody = @"
**[RECOVERY TURN #$recoveryAttempt]** — Stall detected: $stallReason

Subagent response: $($parsedReply ? $parsedReply.recovery_action : 'PARSE_ERROR')
- Next step: $($parsedReply ? $parsedReply.next_step_description : 'N/A')
- Needs from lead: $($parsedReply ? $parsedReply.required_input : 'N/A')
- Est. completion: $($parsedReply ? $parsedReply.estimated_completion_cycles : 'N/A')

Evidence: [recovery-turn-$recoveryAttempt-$guid.json](file://$evidenceFile)
"@

    $commentPayload = @{ message = $commentBody } | ConvertTo-Json -Depth 10
    $commentUri = "$BaseUrl/api/v1/agent/boards/$([uri]::EscapeDataString($BoardId))/tasks/$([uri]::EscapeDataString($taskId))/comments"
    try {
        Invoke-RestMethod -Uri $commentUri -Method Post -Headers @{ 'X-Agent-Token' = $AuthToken } -ContentType 'application/json' -Body $commentPayload -TimeoutSec 30 | Out-Null
        Write-Host "[{0}] Comment posted to task {1}" -f (Get-Date).ToString('o'), $taskId
    } catch {
        Write-Warning "Failed to post comment to task: $_"
    }

    if ($parseSuccess) {
        return $true
    } else {
        throw "Recovery reply parse failed"
    }
}

function Invoke-MconHeartbeatQueueProcessor {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$TimeoutSec = 300
    )

    $lockState = Request-MconHeartbeatQueueLock -WorkspacePath $WorkspacePath
    if (-not $lockState.acquired) { return $false }

    # Clean up any stuck processing items before starting
    $stuckCount = Clear-MconHeartbeatStuckProcessingItems -QueuePaths $lockState.paths -MaxProcessingMinutes 10
    $stdoutLogPath = $lockState.paths.stdoutLog
    $stderrLogPath = $lockState.paths.stderrLog
    Write-MconQueueLog -Path $stdoutLogPath -Message "queue processor started workspace=$WorkspacePath invocation_agent=$InvocationAgent"
    if ($stuckCount -gt 0) {
        Write-MconQueueLog -Path $stdoutLogPath -Message "cleaned up $stuckCount stuck processing items"
    }

    $itemsProcessed = 0
    $itemsFailed = 0

    try {
        while ($true) {
            $nextItem = @(
                Get-ChildItem -LiteralPath $lockState.paths.pending -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime, Name |
                    Select-Object -First 1
            )
            if ($nextItem.Count -eq 0) { break }

            $pendingItem = $nextItem[0]
            $processingPath = Join-Path $lockState.paths.processing $pendingItem.Name
            Move-Item -LiteralPath $pendingItem.FullName -Destination $processingPath -Force

            $queueItem = $null
            try {
                $queueItem = Get-Content -LiteralPath $processingPath -Raw | ConvertFrom-Json -Depth 50
                $taskId = if ($queueItem.task_id) { $queueItem.task_id } else { $queueItem.queue_item_id }
                $dispatchType = if (
                    $queueItem.dispatch_state -and
                    $queueItem.dispatch_state.PSObject.Properties.Name -contains 'dispatch_type' -and
                    $queueItem.dispatch_state.dispatch_type
                ) {
                    [string]$queueItem.dispatch_state.dispatch_type
                } else {
                    'heartbeat'
                }
                $sessionKey = if ($queueItem.PSObject.Properties.Name -contains 'session_key' -and $queueItem.session_key) {
                    [string]$queueItem.session_key
                } else {
                    $null
                }
                if ([string]::IsNullOrWhiteSpace($sessionKey)) {
                    $sessionKey = Get-MconTaskSessionKey -InvocationAgent $InvocationAgent -DispatchState $queueItem.dispatch_state
                }
                Write-MconQueueLog -Path $stdoutLogPath -Message "processing task=$taskId dispatch_type=$dispatchType session_key=$sessionKey"

                $commandOutput = $null
                $commandExitCode = $null
                $commandName = $dispatchType
                if ($dispatchType -eq 'recovery') {
                    $commandName = 'recovery'
                    $null = Invoke-MconRecoveryPrompt `
                        -WorkspacePath $WorkspacePath `
                        -InvocationAgent $InvocationAgent `
                        -DispatchState $queueItem.dispatch_state `
                        -AuthToken $Config.auth_token `
                        -BaseUrl $Config.base_url `
                        -BoardId $Config.board_id `
                        -TimeoutSec $TimeoutSec
                    Write-MconQueueLog -Path $stdoutLogPath -Message "completed recovery task=$taskId"
                } elseif ($dispatchType -eq 'verify') {
                    $commandName = 'verify'
                    $commandResult = Invoke-MconVerifierAgent `
                        -WorkspacePath $WorkspacePath `
                        -InvocationAgent $InvocationAgent `
                        -DispatchState $queueItem.dispatch_state `
                        -AuthToken $Config.auth_token `
                        -SessionKey $sessionKey `
                        -TimeoutSec $TimeoutSec
                    $commandExitCode = $commandResult.exit_code
                    $commandOutput = [string]$commandResult.output
                    Write-MconQueueLog -Path $stdoutLogPath -Message "verify exit_code=$commandExitCode task=$taskId session_key=$sessionKey"
                    Write-MconQueueOutput -Path $stdoutLogPath -Prefix "verify output:" -Text $commandOutput
                    if ($commandExitCode -ne 0) {
                        throw "Verifier command failed with exit code $commandExitCode"
                    }
                } else {
                    $commandName = 'heartbeat'
                    $commandOutput = Invoke-MconHeartbeatAgent `
                        -WorkspacePath $WorkspacePath `
                        -InvocationAgent $InvocationAgent `
                        -DispatchState $queueItem.dispatch_state `
                        -AuthToken $Config.auth_token `
                        -SessionKey $sessionKey
                    Write-MconQueueOutput -Path $stdoutLogPath -Prefix "heartbeat output:" -Text ([string]$commandOutput)
                }

                Remove-Item -LiteralPath $processingPath -Force
                $itemsProcessed++
                Write-MconQueueLog -Path $stdoutLogPath -Message "completed task=$taskId command=$commandName"
            } catch {
                $itemsFailed++
                $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
                $failureName = "$($pendingItem.BaseName)-failure-$ts.json"
                $failurePath = Join-Path $lockState.paths.failed $failureName
                $failureRecord = [ordered]@{
                    failed_at   = (Get-Date).ToUniversalTime().ToString('o')
                    error       = ($_ | Out-String).Trim()
                    command     = $commandName
                    command_exit_code = $commandExitCode
                    command_output = $commandOutput
                    queue_item  = $queueItem
                }
                $failureRecord | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $failurePath -Encoding UTF8
                Write-MconQueueLog -Path $stderrLogPath -Message "FAILED task=$($pendingItem.Name) command=$commandName"
                Write-MconQueueOutput -Path $stderrLogPath -Prefix "failure error:" -Text $failureRecord.error
                if (-not [string]::IsNullOrWhiteSpace([string]$commandOutput)) {
                    Write-MconQueueOutput -Path $stderrLogPath -Prefix "failure output:" -Text ([string]$commandOutput)
                }

                if (Test-Path -LiteralPath $processingPath) {
                    Remove-Item -LiteralPath $processingPath -Force
                }

                Write-Error ("queue item failed: {0}`n{1}" -f $pendingItem.Name, (($_ | Out-String).Trim()))
            }
        }

        Write-MconQueueLog -Path $stdoutLogPath -Message "queue processor idle processed=$itemsProcessed failed=$itemsFailed"
        return [ordered]@{
            items_processed = $itemsProcessed
            items_failed    = $itemsFailed
        }
    } finally {
        Unlock-MconHeartbeatQueueLock -QueuePaths $lockState.paths
    }
}

Export-ModuleMember -Function Get-MconOpenClawGatewayConfig, Get-MconTaskSessionKey, New-MconHeartbeatPrompt, Invoke-MconOpenClawGatewayChat, Invoke-MconHeartbeatAgent, Get-MconHeartbeatQueuePaths, Initialize-MconHeartbeatQueue, Test-MconHeartbeatProcessAlive, Restore-MconHeartbeatProcessingQueue, Clear-MconHeartbeatStuckProcessingItems, Get-MconHeartbeatQueueLockState, Test-MconHeartbeatQueueProcessing, Request-MconHeartbeatQueueLock, Unlock-MconHeartbeatQueueLock, Get-MconHeartbeatQueueItemId, Add-MconHeartbeatQueueItem, Start-MconHeartbeatQueueProcessor, Get-MconHeartbeatDispatchStates, Invoke-MconRecoveryPrompt, Invoke-MconHeartbeatQueueProcessor
