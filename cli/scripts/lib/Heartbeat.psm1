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

function Invoke-MconHeartbeatAgent {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)]$DispatchState,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$SessionKey,
        [int]$TimeoutSec = 120,
        [string]$LogPath = $null,
        [string]$TaskId = $null,
        [string]$DispatchType = 'heartbeat',
        [string]$QueueItemId = $null
    )

    if (-not $TaskId) {
        $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
        if ($firstTask -and $firstTask.id) {
            $TaskId = [string]$firstTask.id
        }
    }

    $prompt = New-MconHeartbeatPrompt -WorkspacePath $WorkspacePath -DispatchState $DispatchState -AuthToken $AuthToken -SessionKey $SessionKey
    $response = Send-MconOpenClawSessionMessage `
        -WorkspacePath $WorkspacePath `
        -InvocationAgent $InvocationAgent `
        -Message $prompt `
        -SessionKey $SessionKey `
        -TimeoutSec $TimeoutSec `
        -LogPath $LogPath `
        -TaskId $TaskId `
        -DispatchType $DispatchType `
        -QueueItemId $QueueItemId

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
        workflow        = $workflowPath
        root            = $queueRoot
        pending         = Join-Path $queueRoot 'pending'
        processing      = Join-Path $queueRoot 'processing'
        failed          = Join-Path $queueRoot 'failed'
        retired         = Join-Path $queueRoot 'retired'
        processorRuns   = Join-Path $queueRoot 'processor-runs'
        processorLatest = Join-Path $queueRoot 'processor.latest.json'
        lock            = Join-Path $queueRoot 'processing.lock.json'
        stdoutLog       = Join-Path $queueRoot 'processor.stdout.log'
        stderrLog       = Join-Path $queueRoot 'processor.stderr.log'
    }
}

function Initialize-MconHeartbeatQueue {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $paths = Get-MconHeartbeatQueuePaths -WorkspacePath $WorkspacePath
    foreach ($dir in @($paths.workflow, $paths.root, $paths.pending, $paths.processing, $paths.failed, $paths.processorRuns)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    return $paths
}

function Get-MconHeartbeatProcessorRunPath {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        [Parameter(Mandatory)][string]$LaunchId
    )

    return Join-Path $QueuePaths.processorRuns "$LaunchId.json"
}

function Read-MconHeartbeatProcessorRunState {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        [Parameter(Mandatory)][string]$LaunchId
    )

    $runPath = Get-MconHeartbeatProcessorRunPath -QueuePaths $QueuePaths -LaunchId $LaunchId
    if (-not (Test-Path -LiteralPath $runPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -Depth 20
    } catch {
        return $null
    }
}

function Write-MconHeartbeatProcessorRunState {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        [Parameter(Mandatory)][string]$LaunchId,
        [Parameter(Mandatory)][string]$State,
        [hashtable]$Fields = @{}
    )

    $existing = Read-MconHeartbeatProcessorRunState -QueuePaths $QueuePaths -LaunchId $LaunchId
    $record = [ordered]@{}

    if ($existing) {
        foreach ($prop in $existing.PSObject.Properties) {
            $record[$prop.Name] = $prop.Value
        }
    }

    if (-not $record.Contains('launch_id')) {
        $record.launch_id = $LaunchId
    }
    if (-not $record.Contains('created_at')) {
        $record.created_at = (Get-Date).ToUniversalTime().ToString('o')
    }

    $record.state = $State
    $record.updated_at = (Get-Date).ToUniversalTime().ToString('o')

    foreach ($key in $Fields.Keys) {
        $record[$key] = $Fields[$key]
    }

    $runPath = Get-MconHeartbeatProcessorRunPath -QueuePaths $QueuePaths -LaunchId $LaunchId
    $tmpPath = "$runPath.tmp"
    $json = $record | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $tmpPath -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmpPath -Destination $runPath -Force

    $latestTmpPath = "$($QueuePaths.processorLatest).tmp"
    Set-Content -LiteralPath $latestTmpPath -Value $json -Encoding UTF8
    Move-Item -LiteralPath $latestTmpPath -Destination $QueuePaths.processorLatest -Force

    return [pscustomobject]$record
}

function Wait-MconHeartbeatQueueProcessorStart {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        [Parameter(Mandatory)][string]$LaunchId,
        [int]$ProcessId = 0,
        [int]$TimeoutSec = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $runState = Read-MconHeartbeatProcessorRunState -QueuePaths $QueuePaths -LaunchId $LaunchId
        if ($runState -and $runState.state -in @('started', 'processing', 'completed')) {
            return [ordered]@{
                launch_id           = $LaunchId
                launched            = $true
                confirmed_started   = $true
                state               = [string]$runState.state
                pid                 = if ($runState.PSObject.Properties.Name -contains 'pid') { $runState.pid } else { $ProcessId }
                run_path            = Get-MconHeartbeatProcessorRunPath -QueuePaths $QueuePaths -LaunchId $LaunchId
                latest_path         = $QueuePaths.processorLatest
                stdout_log          = $QueuePaths.stdoutLog
                stderr_log          = $QueuePaths.stderrLog
                startup_timeout_sec = $TimeoutSec
                error               = $null
            }
        }

        if ($runState -and $runState.state -in @('lock_active', 'launch_failed', 'exited_before_start')) {
            return [ordered]@{
                launch_id           = $LaunchId
                launched            = $true
                confirmed_started   = $false
                state               = [string]$runState.state
                pid                 = if ($runState.PSObject.Properties.Name -contains 'pid') { $runState.pid } else { $ProcessId }
                run_path            = Get-MconHeartbeatProcessorRunPath -QueuePaths $QueuePaths -LaunchId $LaunchId
                latest_path         = $QueuePaths.processorLatest
                stdout_log          = $QueuePaths.stdoutLog
                stderr_log          = $QueuePaths.stderrLog
                startup_timeout_sec = $TimeoutSec
                error               = if ($runState.PSObject.Properties.Name -contains 'error') { $runState.error } else { $null }
            }
        }

        if ($ProcessId -gt 0 -and -not (Test-MconHeartbeatProcessAlive -ProcessId $ProcessId)) {
            $runState = Write-MconHeartbeatProcessorRunState `
                -QueuePaths $QueuePaths `
                -LaunchId $LaunchId `
                -State 'exited_before_start' `
                -Fields @{
                    pid   = $ProcessId
                    error = 'Processor process exited before confirming queue startup.'
                }
            return [ordered]@{
                launch_id           = $LaunchId
                launched            = $true
                confirmed_started   = $false
                state               = 'exited_before_start'
                pid                 = $ProcessId
                run_path            = Get-MconHeartbeatProcessorRunPath -QueuePaths $QueuePaths -LaunchId $LaunchId
                latest_path         = $QueuePaths.processorLatest
                stdout_log          = $QueuePaths.stdoutLog
                stderr_log          = $QueuePaths.stderrLog
                startup_timeout_sec = $TimeoutSec
                error               = $runState.error
            }
        }

        Start-Sleep -Milliseconds 250
    }

    $runState = Read-MconHeartbeatProcessorRunState -QueuePaths $QueuePaths -LaunchId $LaunchId
    return [ordered]@{
        launch_id           = $LaunchId
        launched            = $true
        confirmed_started   = $false
        state               = if ($runState -and $runState.PSObject.Properties.Name -contains 'state') { [string]$runState.state } else { 'launch_pending' }
        pid                 = if ($runState -and $runState.PSObject.Properties.Name -contains 'pid') { $runState.pid } else { $ProcessId }
        run_path            = Get-MconHeartbeatProcessorRunPath -QueuePaths $QueuePaths -LaunchId $LaunchId
        latest_path         = $QueuePaths.processorLatest
        stdout_log          = $QueuePaths.stdoutLog
        stderr_log          = $QueuePaths.stderrLog
        startup_timeout_sec = $TimeoutSec
        error               = if ($runState -and $runState.PSObject.Properties.Name -contains 'error') { $runState.error } else { $null }
    }
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
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-MconQueueLog -Path $LogPath -Message "moving stuck processing item to failed: $($item.Name)"
        }
        Move-Item -LiteralPath $item.FullName -Destination $failedPath -Force
    }

    return $stuckItems.Count
}

function Repair-MconHeartbeatProcessorRunAfterUnexpectedExit {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        $LockData = $null
    )

    if (-not (Test-Path -LiteralPath $QueuePaths.processorLatest)) {
        return
    }

    $latestRun = $null
    try {
        $latestRun = Get-Content -LiteralPath $QueuePaths.processorLatest -Raw | ConvertFrom-Json -Depth 20
    } catch {
        return
    }

    if (-not $latestRun) {
        return
    }

    $launchId = if ($latestRun.PSObject.Properties.Name -contains 'launch_id') { [string]$latestRun.launch_id } else { $null }
    if ([string]::IsNullOrWhiteSpace($launchId)) {
        return
    }

    $terminalStates = @('completed', 'launch_failed', 'lock_active', 'exited_before_start', 'exited_unexpectedly')
    $previousState = if ($latestRun.PSObject.Properties.Name -contains 'state') { [string]$latestRun.state } else { '' }
    if ($previousState -in $terminalStates) {
        return
    }

    $lockPid = $null
    if ($LockData -and $LockData.PSObject.Properties.Name -contains 'pid' -and $LockData.pid) {
        $lockPid = [int]$LockData.pid
    }

    $runPid = $null
    if ($latestRun.PSObject.Properties.Name -contains 'pid' -and $latestRun.pid) {
        $runPid = [int]$latestRun.pid
    }

    if ($lockPid -and $runPid -and $lockPid -ne $runPid) {
        return
    }

    $recoveredQueueItem = if ($latestRun.PSObject.Properties.Name -contains 'current_queue_item') {
        [string]$latestRun.current_queue_item
    } else {
        $null
    }

    $fields = @{
        pid            = if ($runPid) { $runPid } else { $lockPid }
        previous_state = $previousState
        exited_at      = (Get-Date).ToUniversalTime().ToString('o')
        error          = if ($lockPid) {
            "Processor process $lockPid exited unexpectedly while state was $previousState."
        } else {
            "Processor exited unexpectedly while state was $previousState."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($recoveredQueueItem)) {
        $fields.recovered_queue_item = $recoveredQueueItem
    }

    Write-MconHeartbeatProcessorRunState `
        -QueuePaths $QueuePaths `
        -LaunchId $launchId `
        -State 'exited_unexpectedly' `
        -Fields $fields | Out-Null
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

    if ($lockPid -and (Test-MconHeartbeatProcessAlive -ProcessId $lockPid)) {
        return [pscustomobject]@{
            active = $true
            paths  = $paths
            lock   = $lockData
        }
    }

    Repair-MconHeartbeatProcessorRunAfterUnexpectedExit -QueuePaths $paths -LockData $lockData
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

function Get-MconHeartbeatQueueFailureFiles {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        [Parameter(Mandatory)][string]$QueueItemId
    )

    return @(
        Get-ChildItem -LiteralPath $QueuePaths.failed -Filter "$QueueItemId-*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime, Name
    )
}

function Get-MconHeartbeatQueueRetryBackoffMinutes {
    param(
        [Parameter(Mandatory)][int]$FailureCount,
        [int]$BaseMinutes = 15,
        [int]$MaxMinutes = 360
    )

    if ($FailureCount -le 0) {
        return 0
    }

    $exponent = [Math]::Min([int]($FailureCount - 1), 30)
    $backoffMinutes = [int][Math]::Round([double]$BaseMinutes * [Math]::Pow(2, $exponent))
    return [int][Math]::Min($backoffMinutes, $MaxMinutes)
}

function Get-MconHeartbeatQueueCooldownState {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        [Parameter(Mandatory)][string]$QueueItemId,
        [int]$RetryBackoffMinutes = 15,
        [int]$MaxRetryBackoffMinutes = 360
    )

    $failedFiles = @(Get-MconHeartbeatQueueFailureFiles -QueuePaths $QueuePaths -QueueItemId $QueueItemId)
    if ($failedFiles.Count -eq 0) {
        return [pscustomobject]@{
            active            = $false
            failure_count     = 0
            backoff_minutes   = 0
            last_failure_at   = $null
            next_attempt_at   = $null
            remaining_minutes = 0
        }
    }

    $lastFailure = $failedFiles[$failedFiles.Count - 1]
    $lastFailureAt = $lastFailure.LastWriteTime.ToUniversalTime()
    $backoffMinutes = Get-MconHeartbeatQueueRetryBackoffMinutes `
        -FailureCount $failedFiles.Count `
        -BaseMinutes $RetryBackoffMinutes `
        -MaxMinutes $MaxRetryBackoffMinutes
    $nextAttemptAt = $lastFailureAt.AddMinutes($backoffMinutes)
    $remainingMinutes = [int][Math]::Ceiling(($nextAttemptAt - (Get-Date).ToUniversalTime()).TotalMinutes)

    return [pscustomobject]@{
        active            = $remainingMinutes -gt 0
        failure_count     = $failedFiles.Count
        backoff_minutes   = $backoffMinutes
        last_failure_at   = $lastFailureAt.ToString('o')
        next_attempt_at   = $nextAttemptAt.ToString('o')
        remaining_minutes = [int][Math]::Max(0, $remainingMinutes)
    }
}

function Clear-MconHeartbeatQueueFailureHistory {
    param(
        [Parameter(Mandatory)]$QueuePaths,
        [Parameter(Mandatory)][string]$QueueItemId
    )

    $removedCount = 0
    foreach ($failedFile in @(Get-MconHeartbeatQueueFailureFiles -QueuePaths $QueuePaths -QueueItemId $QueueItemId)) {
        Remove-Item -LiteralPath $failedFile.FullName -Force -ErrorAction SilentlyContinue
        $removedCount++
    }

    $retiredPath = Join-Path $QueuePaths.retired "$QueueItemId.json"
    if (Test-Path -LiteralPath $retiredPath) {
        Remove-Item -LiteralPath $retiredPath -Force -ErrorAction SilentlyContinue
    }

    return $removedCount
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
        [int]$RetryBackoffMinutes = 15,
        [int]$MaxRetryBackoffMinutes = 360,
        [int]$MaxFailures = 0
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

    $cooldownState = Get-MconHeartbeatQueueCooldownState `
        -QueuePaths $paths `
        -QueueItemId $queueItemId `
        -RetryBackoffMinutes $RetryBackoffMinutes `
        -MaxRetryBackoffMinutes $MaxRetryBackoffMinutes

    if ($cooldownState.active) {
        Write-MconQueueLog `
            -Path $paths.stdoutLog `
            -Message "SKIP cooldown $queueItemId failures=$($cooldownState.failure_count) remaining_minutes=$($cooldownState.remaining_minutes) next_attempt_at=$($cooldownState.next_attempt_at)"
        return 'cooldown'
    }

    $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
    $queueItem = [ordered]@{
        queue_item_id    = $queueItemId
        enqueued_at      = (Get-Date).ToUniversalTime().ToString('o')
        invocation_agent = $InvocationAgent
        session_key      = Get-MconTaskSessionKey -InvocationAgent $InvocationAgent -DispatchState $DispatchState
        dispatch_state   = $DispatchState
    }

    if ($firstTask -and $firstTask.id) {
        $queueItem.task_id = $firstTask.id
        $queueItem.task_status = $firstTask.status
    }
    if ($cooldownState.failure_count -gt 0) {
        $queueItem.consecutive_failures = $cooldownState.failure_count
        Write-MconQueueLog `
            -Path $paths.stdoutLog `
            -Message "REQUEUE $queueItemId after_failures=$($cooldownState.failure_count) last_failure_at=$($cooldownState.last_failure_at)"
    }

    $queueItem | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $pendingPath -Encoding UTF8
    Write-MconQueueLog -Path $paths.stdoutLog -Message "QUEUED $queueItemId dispatch_type=$($DispatchState.dispatch_type) session_key=$($queueItem.session_key)"
    return 'queued'
}

function ConvertTo-MconBashSingleQuotedString {
    param(
        [Parameter(Mandatory)][string]$Value
    )

    return "'" + ($Value -replace "'", "'""'""'") + "'"
}

function Get-MconHeartbeatQueueIdentityEnvironmentNames {
    return @(
        'MCON_AUTH_TOKEN',
        'MCON_BASE_URL',
        'MCON_BOARD_ID',
        'MCON_AGENT_ID',
        'MCON_WSP'
    )
}

function Start-MconDetachedHeartbeatQueueProcess {
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$MconScriptPath,
        [Parameter(Mandatory)][string]$LaunchId,
        [Parameter(Mandatory)][string]$StdoutLogPath,
        [Parameter(Mandatory)][string]$StderrLogPath
    )

    if (-not ($IsLinux -or $IsMacOS)) {
        $cleanEnvironment = @{}
        foreach ($name in (Get-MconHeartbeatQueueIdentityEnvironmentNames)) {
            $cleanEnvironment[$name] = ''
        }

        return Start-Process `
            -FilePath $PwshPath `
            -ArgumentList @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $MconScriptPath, 'workflow', 'dispatch', '--process-queue', '--processor-launch-id', $LaunchId) `
            -WorkingDirectory $WorkspacePath `
            -RedirectStandardOutput $StdoutLogPath `
            -RedirectStandardError $StderrLogPath `
            -Environment $cleanEnvironment `
            -PassThru
    }

    $bashPath = (Get-Command bash -ErrorAction Stop).Source
    $envPath = (Get-Command env -ErrorAction Stop).Source
    $setsidPath = $null
    try {
        $setsidPath = (Get-Command setsid -ErrorAction Stop).Source
    } catch {
        $setsidPath = $null
    }

    $commandWords = @()
    if (-not [string]::IsNullOrWhiteSpace($setsidPath)) {
        $commandWords += (ConvertTo-MconBashSingleQuotedString -Value $setsidPath)
    }
    $commandWords += (ConvertTo-MconBashSingleQuotedString -Value $envPath)
    foreach ($name in (Get-MconHeartbeatQueueIdentityEnvironmentNames)) {
        $commandWords += '-u'
        $commandWords += $name
    }
    $commandWords += (ConvertTo-MconBashSingleQuotedString -Value $PwshPath)
    $commandWords += @(
        '-NoProfile',
        '-NoLogo',
        '-NonInteractive',
        '-File',
        (ConvertTo-MconBashSingleQuotedString -Value $MconScriptPath),
        'workflow',
        'dispatch',
        '--process-queue',
        '--processor-launch-id',
        (ConvertTo-MconBashSingleQuotedString -Value $LaunchId)
    )

    $launchCommand = @(
        "cd {0} || exit 1" -f (ConvertTo-MconBashSingleQuotedString -Value $WorkspacePath)
        "nohup {0} </dev/null >> {1} 2>> {2} &" -f (
            ($commandWords -join ' '),
            (ConvertTo-MconBashSingleQuotedString -Value $StdoutLogPath),
            (ConvertTo-MconBashSingleQuotedString -Value $StderrLogPath)
        )
        'echo $!'
    ) -join "`n"

    $launchOutput = & $bashPath '-lc' $launchCommand 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errorText = ($launchOutput | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $errorText = "bash launcher exited with code $LASTEXITCODE"
        }
        throw $errorText
    }

    $pidLine = @(
        $launchOutput |
        ForEach-Object { [string]$_ } |
        Where-Object { $_ -match '^\d+$' } |
        Select-Object -Last 1
    )
    if ($pidLine.Count -eq 0) {
        $errorText = ($launchOutput | Out-String).Trim()
        throw "Detached queue launch did not return a PID. Output: $errorText"
    }

    return [pscustomobject]@{
        Id = [int]$pidLine[0]
    }
}

function Resolve-MconHeartbeatQueueScriptPath {
    param(
        [Parameter(Mandatory)][string]$MconScriptPath
    )

    if ([string]::IsNullOrWhiteSpace($MconScriptPath)) {
        throw 'Queue processor launch requires a non-empty mcon script path.'
    }

    $resolvedPath = $null
    if (Test-Path -LiteralPath $MconScriptPath) {
        $resolvedPath = (Resolve-Path -LiteralPath $MconScriptPath).Path
    } else {
        $resolvedPath = $MconScriptPath
    }

    if ((Split-Path -Path $resolvedPath -Leaf) -ieq 'mcon.ps1') {
        return $resolvedPath
    }

    $repoCliScript = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'mcon.ps1'
    if (Test-Path -LiteralPath $repoCliScript) {
        return (Resolve-Path -LiteralPath $repoCliScript).Path
    }

    throw "Queue processor launch path must point at mcon.ps1; got '$MconScriptPath'."
}

function Start-MconHeartbeatQueueProcessor {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$MconScriptPath,
        [int]$StartupTimeoutSec = 10
    )

    $state = Get-MconHeartbeatQueueLockState -WorkspacePath $WorkspacePath
    $originalMconScriptPath = $MconScriptPath
    $MconScriptPath = Resolve-MconHeartbeatQueueScriptPath -MconScriptPath $MconScriptPath
    if ($MconScriptPath -ne $originalMconScriptPath) {
        Write-MconQueueLog -Path $state.paths.stdoutLog -Message "queue processor normalized script_path from=$originalMconScriptPath to=$MconScriptPath"
    }

    if ($state.active) {
        Write-MconQueueLog -Path $state.paths.stdoutLog -Message "queue processor start skipped lock_active pid=$($state.lock.pid)"
        return [ordered]@{
            launched            = $false
            confirmed_started   = $false
            state               = 'lock_active'
            pid                 = if ($state.lock) { $state.lock.pid } else { $null }
            run_path            = $null
            latest_path         = $state.paths.processorLatest
            stdout_log          = $state.paths.stdoutLog
            stderr_log          = $state.paths.stderrLog
            startup_timeout_sec = $StartupTimeoutSec
            error               = 'Queue processor lock is already active.'
        }
    }

    $pendingItems = @(
        Get-ChildItem -LiteralPath $state.paths.pending -Filter '*.json' -File -ErrorAction SilentlyContinue
    )
    if ($pendingItems.Count -eq 0) {
        Write-MconQueueLog -Path $state.paths.stdoutLog -Message "queue processor start skipped pending=0"
        return [ordered]@{
            launched            = $false
            confirmed_started   = $false
            state               = 'pending_empty'
            pid                 = $null
            run_path            = $null
            latest_path         = $state.paths.processorLatest
            stdout_log          = $state.paths.stdoutLog
            stderr_log          = $state.paths.stderrLog
            startup_timeout_sec = $StartupTimeoutSec
            error               = 'No pending queue items were available.'
        }
    }

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $launchId = [guid]::NewGuid().Guid
    $runPath = Get-MconHeartbeatProcessorRunPath -QueuePaths $state.paths -LaunchId $launchId
    Write-MconHeartbeatProcessorRunState `
        -QueuePaths $state.paths `
        -LaunchId $launchId `
        -State 'launching' `
        -Fields @{
            workspace_path = $WorkspacePath
            script_path    = $MconScriptPath
            pending_count  = $pendingItems.Count
        } | Out-Null

    try {
        $process = Start-MconDetachedHeartbeatQueueProcess `
            -PwshPath $pwshPath `
            -WorkspacePath $WorkspacePath `
            -MconScriptPath $MconScriptPath `
            -LaunchId $launchId `
            -StdoutLogPath $state.paths.stdoutLog `
            -StderrLogPath $state.paths.stderrLog
    } catch {
        $errorText = ($_ | Out-String).Trim()
        Write-MconHeartbeatProcessorRunState `
            -QueuePaths $state.paths `
            -LaunchId $launchId `
            -State 'launch_failed' `
            -Fields @{
                workspace_path = $WorkspacePath
                script_path    = $MconScriptPath
                error          = $errorText
            } | Out-Null
        Write-MconQueueLog -Path $state.paths.stderrLog -Message "queue processor launch failed launch_id=$launchId error=$errorText"
        return [ordered]@{
            launched            = $false
            confirmed_started   = $false
            state               = 'launch_failed'
            pid                 = $null
            launch_id           = $launchId
            run_path            = $runPath
            latest_path         = $state.paths.processorLatest
            stdout_log          = $state.paths.stdoutLog
            stderr_log          = $state.paths.stderrLog
            startup_timeout_sec = $StartupTimeoutSec
            error               = $errorText
        }
    }

    Write-MconHeartbeatProcessorRunState `
        -QueuePaths $state.paths `
        -LaunchId $launchId `
        -State 'launched' `
        -Fields @{
            pid            = $process.Id
            launched_at    = (Get-Date).ToUniversalTime().ToString('o')
            workspace_path = $WorkspacePath
            script_path    = $MconScriptPath
            pending_count  = $pendingItems.Count
            stdout_log     = $state.paths.stdoutLog
            stderr_log     = $state.paths.stderrLog
        } | Out-Null

    Write-MconQueueLog -Path $state.paths.stdoutLog -Message "queue processor start launched pid=$($process.Id) pending=$($pendingItems.Count) launch_id=$launchId"
    return (Wait-MconHeartbeatQueueProcessorStart -QueuePaths $state.paths -LaunchId $launchId -ProcessId $process.Id -TimeoutSec $StartupTimeoutSec)
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
        [int]$TimeoutSec = 60,
        [string]$LogPath = $null,
        [string]$TaskId = $null,
        [string]$QueueItemId = $null
    )

    $taskId = if ($TaskId) { $TaskId } else { $DispatchState.task_id }
    $recoveryAttempt = $DispatchState.recovery_attempt
    $stallReason = $DispatchState.stall_reason
    $taskDataPath = $DispatchState.task_data_path

    # Support both new task-scoped field names and legacy subagent field names
    $taskSessionKey = if ($DispatchState.PSObject.Properties.Name -contains 'task_session_key') { $DispatchState.task_session_key } else { $null }
    $taskAgentId = if ($DispatchState.PSObject.Properties.Name -contains 'task_agent_id') { $DispatchState.task_agent_id } else { $null }
    $subagentSessionKey = if ($DispatchState.PSObject.Properties.Name -contains 'subagent_session_key') { $DispatchState.subagent_session_key } else { $null }
    $subagentAgentId = if ($DispatchState.PSObject.Properties.Name -contains 'subagent_agent_id') { $DispatchState.subagent_agent_id } else { $null }

    $sessionKey = if ($taskSessionKey) { $taskSessionKey } else { $subagentSessionKey }
    $agentId = if ($taskAgentId) { $taskAgentId } else { $subagentAgentId }

    if (-not $taskId) { throw "Missing task_id in recovery dispatch_state" }
    if (-not $taskDataPath) { throw "Missing task_data_path in recovery dispatch_state" }

    # If session key or agent id are missing, try to derive them from task data
    if (-not $sessionKey -or -not $agentId) {
        if (Test-Path -LiteralPath $taskDataPath) {
            $taskData = Get-Content -LiteralPath $taskDataPath -Raw | ConvertFrom-Json -Depth 50
            $assignedAgentId = $null
            if ($taskData.task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $taskData.task.assigned_agent_id) {
                $assignedAgentId = [string]$taskData.task.assigned_agent_id
            }
            if ($assignedAgentId) {
                $openClawRoot = Split-Path -Parent $WorkspacePath
                $workerWorkspacePath = Join-Path $openClawRoot "workspace-mc-$assignedAgentId"
                if (Test-Path -LiteralPath $workerWorkspacePath) {
                    try {
                        $workerConfig = Resolve-MconOpenClawAgentConfig -WorkspacePath $workerWorkspacePath
                        $workerSpawnAgentId = if ($workerConfig.PSObject.Properties.Name -contains 'spawn_agent_id') { [string]$workerConfig.spawn_agent_id } else { $null }
                        if (-not [string]::IsNullOrWhiteSpace($workerSpawnAgentId)) {
                            if (-not $sessionKey) {
                                $sessionKey = "agent:$workerSpawnAgentId`:task:$taskId"
                            }
                            if (-not $agentId) {
                                $agentId = $workerSpawnAgentId
                            }
                        }
                    } catch {}
                }
            }
        }
    }

    if (-not $sessionKey) { throw "Missing task_session_key (or subagent_session_key) in recovery dispatch_state" }
    if (-not $agentId) { throw "Missing task_agent_id (or subagent_agent_id) in recovery dispatch_state" }

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

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-MconQueueLog -Path $LogPath -Message "recovery_prompt begin task=$taskId queue_item=$QueueItemId session_key=$sessionKey agent=$agentId attempt=$recoveryAttempt"
    }

    $startTime = Get-Date
    $response = Send-MconOpenClawSessionMessage `
        -WorkspacePath $WorkspacePath `
        -InvocationAgent $agentId `
        -Message $recoveryPrompt `
        -SessionKey $sessionKey `
        -TimeoutSec $TimeoutSec `
        -LogPath $LogPath `
        -TaskId $taskId `
        -DispatchType 'recovery' `
        -QueueItemId $QueueItemId `
        -Temperature 0.3 `
        -MaxTokens 500
    $elapsedMs = ((Get-Date) - $startTime).TotalMilliseconds

    $rawReply = $response.choices[0].message.content
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-MconQueueLog -Path $LogPath -Message "recovery_prompt response task=$taskId queue_item=$QueueItemId elapsed_ms=$([math]::Round($elapsedMs))"
    }

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
        Write-Warning "Failed to parse worker reply as valid JSON: $_"
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-MconQueueLog -Path $LogPath -Message "recovery_prompt parse_failed task=$taskId queue_item=$QueueItemId error=$($_.Exception.Message)"
        }
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
        task_session_key    = $sessionKey
        task_agent_id       = $agentId
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
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-MconQueueLog -Path $LogPath -Message "recovery_prompt evidence_written task=$taskId queue_item=$QueueItemId evidence=$evidenceFile"
    }

    $commentBody = @"
**[RECOVERY TURN #$recoveryAttempt]** — Stall detected: $stallReason

Worker response: $($parsedReply ? $parsedReply.recovery_action : 'PARSE_ERROR')
- Next step: $($parsedReply ? $parsedReply.next_step_description : 'N/A')
- Needs from lead: $($parsedReply ? $parsedReply.required_input : 'N/A')
- Est. completion: $($parsedReply ? $parsedReply.estimated_completion_cycles : 'N/A')

Evidence: [recovery-turn-$recoveryAttempt-$guid.json](file://$evidenceFile)
"@

    $commentPayload = @{ message = $commentBody } | ConvertTo-Json -Depth 10
    $commentUri = "$BaseUrl/api/v1/agent/boards/$([uri]::EscapeDataString($BoardId))/tasks/$([uri]::EscapeDataString($taskId))/comments"
    try {
        Invoke-RestMethod -Uri $commentUri -Method Post -Headers @{ 'X-Agent-Token' = $AuthToken } -ContentType 'application/json' -Body $commentPayload -TimeoutSec 30 | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-MconQueueLog -Path $LogPath -Message "recovery_prompt comment_posted task=$taskId queue_item=$QueueItemId"
        }
    } catch {
        Write-Warning "Failed to post comment to task: $_"
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-MconQueueLog -Path $LogPath -Message "recovery_prompt comment_failed task=$taskId queue_item=$QueueItemId error=$($_.Exception.Message)"
        }
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
        [int]$TimeoutSec = 300,
        [string]$LaunchId = $null
    )

    $queuePaths = Initialize-MconHeartbeatQueue -WorkspacePath $WorkspacePath
    if (-not [string]::IsNullOrWhiteSpace($LaunchId)) {
        Write-MconHeartbeatProcessorRunState `
            -QueuePaths $queuePaths `
            -LaunchId $LaunchId `
            -State 'booting' `
            -Fields @{
                pid              = $PID
                workspace_path   = $WorkspacePath
                invocation_agent = $InvocationAgent
                booted_at        = (Get-Date).ToUniversalTime().ToString('o')
            } | Out-Null
    }

    $lockState = Request-MconHeartbeatQueueLock -WorkspacePath $WorkspacePath
    $stdoutLogPath = $lockState.paths.stdoutLog
    $stderrLogPath = $lockState.paths.stderrLog
    if (-not $lockState.acquired) {
        Write-MconQueueLog -Path $stdoutLogPath -Message "queue processor start skipped lock_active"
        if (-not [string]::IsNullOrWhiteSpace($LaunchId)) {
            Write-MconHeartbeatProcessorRunState `
                -QueuePaths $lockState.paths `
                -LaunchId $LaunchId `
                -State 'lock_active' `
                -Fields @{
                    pid   = $PID
                    error = 'Queue processor lock is already active.'
                } | Out-Null
        }
        return [ordered]@{
            ok              = $false
            reason          = 'lock_active'
            items_processed = 0
            items_failed    = 0
        }
    }

    # Clean up any stuck processing items before starting
    $stuckCount = Clear-MconHeartbeatStuckProcessingItems -QueuePaths $lockState.paths -MaxProcessingMinutes 10 -LogPath $stdoutLogPath
    Write-MconQueueLog -Path $stdoutLogPath -Message "queue processor started workspace=$WorkspacePath invocation_agent=$InvocationAgent"
    if (-not [string]::IsNullOrWhiteSpace($LaunchId)) {
        Write-MconHeartbeatProcessorRunState `
            -QueuePaths $lockState.paths `
            -LaunchId $LaunchId `
            -State 'started' `
            -Fields @{
                pid                = $PID
                started_at         = (Get-Date).ToUniversalTime().ToString('o')
                workspace_path     = $WorkspacePath
                invocation_agent   = $InvocationAgent
                lock_acquired      = $true
                stuck_items_cleared = $stuckCount
            } | Out-Null
    }
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
            Write-MconQueueLog -Path $stdoutLogPath -Message "claiming queue_item=$($pendingItem.Name)"
            if (-not [string]::IsNullOrWhiteSpace($LaunchId)) {
                Write-MconHeartbeatProcessorRunState `
                    -QueuePaths $lockState.paths `
                    -LaunchId $LaunchId `
                    -State 'processing' `
                    -Fields @{
                        pid                   = $PID
                        current_queue_item    = $pendingItem.Name
                        current_item_claimed_at = (Get-Date).ToUniversalTime().ToString('o')
                        items_processed       = $itemsProcessed
                        items_failed          = $itemsFailed
                    } | Out-Null
            }
            Move-Item -LiteralPath $pendingItem.FullName -Destination $processingPath -Force
            Write-MconQueueLog -Path $stdoutLogPath -Message "claimed queue_item=$($pendingItem.Name)"

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
                Write-MconQueueLog -Path $stdoutLogPath -Message "processing queue_item=$($pendingItem.Name) task=$taskId dispatch_type=$dispatchType session_key=$sessionKey"

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
                        -TimeoutSec $TimeoutSec `
                        -LogPath $stdoutLogPath `
                        -TaskId $taskId `
                        -QueueItemId $pendingItem.Name
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
                        -SessionKey $sessionKey `
                        -TimeoutSec $TimeoutSec `
                        -LogPath $stdoutLogPath `
                        -TaskId $taskId `
                        -DispatchType $dispatchType `
                        -QueueItemId $pendingItem.Name
                    Write-MconQueueOutput -Path $stdoutLogPath -Prefix "heartbeat output:" -Text ([string]$commandOutput)
                }

                if (Test-Path -LiteralPath $processingPath) {
                    Remove-Item -LiteralPath $processingPath -Force
                } else {
                    $pendingDuplicatePath = Join-Path $lockState.paths.pending $pendingItem.Name
                    if (Test-Path -LiteralPath $pendingDuplicatePath) {
                        Remove-Item -LiteralPath $pendingDuplicatePath -Force
                        Write-MconQueueLog -Path $stdoutLogPath -Message "removed duplicate pending queue_item=$($pendingItem.Name) after successful command=$commandName"
                    } else {
                        Write-MconQueueLog -Path $stdoutLogPath -Message "processing item already absent after successful command=$commandName queue_item=$($pendingItem.Name)"
                    }
                }
                try {
                    $clearedFailureCount = Clear-MconHeartbeatQueueFailureHistory `
                        -QueuePaths $lockState.paths `
                        -QueueItemId $pendingItem.BaseName
                    if ($clearedFailureCount -gt 0) {
                        Write-MconQueueLog -Path $stdoutLogPath -Message "cleared failure history queue_item=$($pendingItem.Name) count=$clearedFailureCount"
                    }
                } catch {
                    Write-MconQueueLog -Path $stderrLogPath -Message "failed to clear failure history queue_item=$($pendingItem.Name): $($_.Exception.Message)"
                }
                $itemsProcessed++
                Write-MconQueueLog -Path $stdoutLogPath -Message "completed task=$taskId command=$commandName"
            } catch {
                $itemsFailed++
                $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
                $failureName = "$($pendingItem.BaseName)-failure-$ts.json"
                $failurePath = Join-Path $lockState.paths.failed $failureName
                $consecutiveFailures = @(Get-MconHeartbeatQueueFailureFiles -QueuePaths $lockState.paths -QueueItemId $pendingItem.BaseName).Count + 1
                $retryBackoffMinutes = Get-MconHeartbeatQueueRetryBackoffMinutes -FailureCount $consecutiveFailures
                $nextAttemptAt = (Get-Date).ToUniversalTime().AddMinutes($retryBackoffMinutes).ToString('o')
                $failureRecord = [ordered]@{
                    failed_at             = (Get-Date).ToUniversalTime().ToString('o')
                    error                 = ($_ | Out-String).Trim()
                    queue_item_id         = $pendingItem.BaseName
                    queue_item_file       = $pendingItem.Name
                    command               = $commandName
                    command_exit_code     = $commandExitCode
                    command_output        = $commandOutput
                    consecutive_failures  = $consecutiveFailures
                    retry_backoff_minutes = $retryBackoffMinutes
                    next_attempt_at       = $nextAttemptAt
                    queue_item            = $queueItem
                }
                $failureRecord | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $failurePath -Encoding UTF8
                Write-MconQueueLog -Path $stderrLogPath -Message "FAILED task=$($pendingItem.Name) command=$commandName failure_path=$failurePath"
                Write-MconQueueOutput -Path $stderrLogPath -Prefix "failure error:" -Text $failureRecord.error
                if (-not [string]::IsNullOrWhiteSpace([string]$commandOutput)) {
                    Write-MconQueueOutput -Path $stderrLogPath -Prefix "failure output:" -Text ([string]$commandOutput)
                }
                Write-MconQueueLog -Path $stderrLogPath -Message "retry cooldown queue_item=$($pendingItem.Name) consecutive_failures=$consecutiveFailures next_attempt_at=$nextAttemptAt"

                if (Test-Path -LiteralPath $processingPath) {
                    Remove-Item -LiteralPath $processingPath -Force
                }

                Write-MconQueueLog -Path $stderrLogPath -Message "continuing after failed queue_item=$($pendingItem.Name) command=$commandName"
            }
        }

        Write-MconQueueLog -Path $stdoutLogPath -Message "queue processor idle processed=$itemsProcessed failed=$itemsFailed"
        if (-not [string]::IsNullOrWhiteSpace($LaunchId)) {
            Write-MconHeartbeatProcessorRunState `
                -QueuePaths $lockState.paths `
                -LaunchId $LaunchId `
                -State 'completed' `
                -Fields @{
                    pid                = $PID
                    completed_at       = (Get-Date).ToUniversalTime().ToString('o')
                    items_processed    = $itemsProcessed
                    items_failed       = $itemsFailed
                    current_queue_item = $null
                } | Out-Null
        }
        return [ordered]@{
            ok = $true
            items_processed = $itemsProcessed
            items_failed    = $itemsFailed
        }
    } finally {
        Write-MconQueueLog -Path $stdoutLogPath -Message "queue processor unlocking"
        Unlock-MconHeartbeatQueueLock -QueuePaths $lockState.paths
    }
}

Export-ModuleMember -Function Get-MconTaskSessionKey, New-MconHeartbeatPrompt, New-MconVerifierPrompt, Invoke-MconHeartbeatAgent, Get-MconHeartbeatQueuePaths, Initialize-MconHeartbeatQueue, Get-MconHeartbeatProcessorRunPath, Read-MconHeartbeatProcessorRunState, Write-MconHeartbeatProcessorRunState, Wait-MconHeartbeatQueueProcessorStart, Test-MconHeartbeatProcessAlive, Restore-MconHeartbeatProcessingQueue, Clear-MconHeartbeatStuckProcessingItems, Get-MconHeartbeatQueueLockState, Test-MconHeartbeatQueueProcessing, Request-MconHeartbeatQueueLock, Unlock-MconHeartbeatQueueLock, Get-MconHeartbeatQueueItemId, Add-MconHeartbeatQueueItem, Start-MconHeartbeatQueueProcessor, Get-MconHeartbeatDispatchStates, Invoke-MconRecoveryPrompt, Invoke-MconHeartbeatQueueProcessor
