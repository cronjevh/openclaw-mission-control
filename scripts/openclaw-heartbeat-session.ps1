#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OpenClawGatewayConfig {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath
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

    if (-not $port) {
        throw "Gateway port missing in $configPath"
    }
    if (-not $token) {
        throw "Gateway auth token missing in $configPath"
    }
    if (-not $chatEnabled) {
        throw "Gateway chat completions endpoint is disabled in $configPath"
    }

    return [pscustomobject]@{
        port = [int]$port
        token = [string]$token
    }
}

function Read-WorkspaceAuthToken {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath
    )

    $toolsPath = Join-Path $WorkspacePath 'TOOLS.md'
    if (-not (Test-Path -LiteralPath $toolsPath)) {
        throw "TOOLS.md not found at $toolsPath"
    }

    $toolsMatch = [regex]::Match(
        (Get-Content -LiteralPath $toolsPath -Raw),
        '(?m)^\s*AUTH_TOKEN\s*=\s*([^\r\n]+?)\s*$'
    )
    if (-not $toolsMatch.Success) {
        throw "AUTH_TOKEN not found in $toolsPath"
    }

    return $toolsMatch.Groups[1].Value.Trim().Trim('`', '"', "'")
}

function Get-OpenClawTaskSessionKey {
    param(
        [Parameter(Mandatory = $true)][string]$InvocationAgent,
        [Parameter(Mandatory = $true)]$DispatchState
    )

    # OpenClaw isolates by sessionKey; sessionId only names the transcript file.
    $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
    if ($firstTask -and $firstTask.id) {
        return "agent:${InvocationAgent}:task:$($firstTask.id)"
    }

    return "agent:${InvocationAgent}:dispatch-run:$([guid]::NewGuid().Guid)"
}

function New-MissionControlHeartbeatPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)]$DispatchState
    )

    $authToken = Read-WorkspaceAuthToken -WorkspacePath $WorkspacePath
    $tasks = @($DispatchState.tasks | Where-Object { $_ -and $_.id })
    $taskRefs = @()
    foreach ($task in $tasks) {
        $taskDataPath = $null
        if ($task.PSObject.Properties.Name -contains 'task_data_path' -and $task.task_data_path) {
            $taskDataPath = [string]$task.task_data_path
        }
        else {
            $taskDataPath = Join-Path (Join-Path (Join-Path $WorkspacePath 'tasks') $task.id) 'taskData.json'
        }

        $taskDir = Split-Path -Path $taskDataPath -Parent
        $taskRefs += [ordered]@{
            id = $task.id
            status = $task.status
            taskDataPath = $taskDataPath
            taskDir = $taskDir
            deliverablesDir = Join-Path $taskDir 'deliverables'
            evidenceDir = Join-Path $taskDir 'evidence'
        }
    }

    $reviewTasks = @($taskRefs | Where-Object { $_.status -eq 'review' })
    if ($tasks.Count -eq 1 -and $reviewTasks.Count -eq 1) {
        $taskRef = $reviewTasks[0]
        return @"
# REVIEW
Task has been submitted for review. Review now according to the review rules.

Use this task bundle as the authoritative local context:
- [taskData.json]($($taskRef.taskDataPath))
- [deliverables/]($($taskRef.deliverablesDir))
- [evidence/]($($taskRef.evidenceDir))

Task directory:
- [$(Split-Path -Path $taskRef.taskDir -Leaf)]($($taskRef.taskDir))

AUTH_TOKEN=$authToken
"@
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
- task count: $($tasks.Count)

Read these task context files first:
$($taskLinks -join "`n")

AUTH_TOKEN=$authToken

"@
    $sections += (Get-Content -LiteralPath $gatedHeartbeatPath -Raw)
    return ($sections -join "`n")
}

function Invoke-OpenClawGatewayChat {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$InvocationAgent,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$SessionKey,
        [int]$TimeoutSec = 120
    )

    $gateway = Get-OpenClawGatewayConfig -WorkspacePath $WorkspacePath
    $uri = "http://127.0.0.1:$($gateway.port)/v1/chat/completions"
    $headers = @{
        Authorization = "Bearer $($gateway.token)"
        'x-openclaw-session-key' = $SessionKey
    }
    $body = @{
        model = "openclaw/$InvocationAgent"
        messages = @(
            @{
                role = 'user'
                content = $Message
            }
        )
    } | ConvertTo-Json -Depth 10

    return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
}

function Invoke-MissionControlHeartbeatAgent {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$InvocationAgent,
        [Parameter(Mandatory = $true)]$DispatchState,
        [int]$TimeoutSec = 120
    )

    $prompt = New-MissionControlHeartbeatPrompt -WorkspacePath $WorkspacePath -DispatchState $DispatchState
    $sessionKey = Get-OpenClawTaskSessionKey -InvocationAgent $InvocationAgent -DispatchState $DispatchState
    $response = Invoke-OpenClawGatewayChat `
        -WorkspacePath $WorkspacePath `
        -InvocationAgent $InvocationAgent `
        -Message $prompt `
        -SessionKey $sessionKey `
        -TimeoutSec $TimeoutSec

    $response | ConvertTo-Json -Depth 50
}

function Get-MissionControlHeartbeatQueuePaths {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath
    )

    $workflowPath = Join-Path $WorkspacePath '.openclaw/workflows'
    $queueRoot = Join-Path $workflowPath 'mc-board-heartbeat-queue'
    return [pscustomobject]@{
        workflow = $workflowPath
        root = $queueRoot
        pending = Join-Path $queueRoot 'pending'
        processing = Join-Path $queueRoot 'processing'
        failed = Join-Path $queueRoot 'failed'
        lock = Join-Path $queueRoot 'processing.lock.json'
        stdoutLog = Join-Path $queueRoot 'processor.stdout.log'
        stderrLog = Join-Path $queueRoot 'processor.stderr.log'
    }
}

function Ensure-MissionControlHeartbeatQueue {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath
    )

    $paths = Get-MissionControlHeartbeatQueuePaths -WorkspacePath $WorkspacePath
    foreach ($dir in @($paths.workflow, $paths.root, $paths.pending, $paths.processing, $paths.failed)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    return $paths
}

function Test-MissionControlHeartbeatProcessAlive {
    param(
        [int]$Pid
    )

    if (-not $Pid) {
        return $false
    }

    try {
        Get-Process -Id $Pid -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Restore-MissionControlHeartbeatProcessingQueue {
    param(
        [Parameter(Mandatory = $true)]$QueuePaths
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

function Get-MissionControlHeartbeatQueueLockState {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath
    )

    $paths = Ensure-MissionControlHeartbeatQueue -WorkspacePath $WorkspacePath
    if (-not (Test-Path -LiteralPath $paths.lock)) {
        return [pscustomobject]@{
            active = $false
            paths = $paths
            lock = $null
        }
    }

    $lockData = $null
    try {
        $lockData = Get-Content -LiteralPath $paths.lock -Raw | ConvertFrom-Json -Depth 10
    }
    catch {
        Remove-Item -LiteralPath $paths.lock -Force
        Restore-MissionControlHeartbeatProcessingQueue -QueuePaths $paths
        return [pscustomobject]@{
            active = $false
            paths = $paths
            lock = $null
        }
    }

    $lockPid = $null
    if ($lockData -and $lockData.PSObject.Properties.Name -contains 'pid' -and $lockData.pid) {
        $lockPid = [int]$lockData.pid
    }

    if ($lockPid -and (Test-MissionControlHeartbeatProcessAlive -Pid $lockPid)) {
        return [pscustomobject]@{
            active = $true
            paths = $paths
            lock = $lockData
        }
    }

    Remove-Item -LiteralPath $paths.lock -Force
    Restore-MissionControlHeartbeatProcessingQueue -QueuePaths $paths
    return [pscustomobject]@{
        active = $false
        paths = $paths
        lock = $lockData
    }
}

function Test-MissionControlHeartbeatQueueProcessing {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath
    )

    $state = Get-MissionControlHeartbeatQueueLockState -WorkspacePath $WorkspacePath
    return [bool]$state.active
}

function Try-Acquire-MissionControlHeartbeatQueueLock {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath
    )

    $state = Get-MissionControlHeartbeatQueueLockState -WorkspacePath $WorkspacePath
    if ($state.active) {
        return [pscustomobject]@{
            acquired = $false
            paths = $state.paths
        }
    }

    $lockPayload = [ordered]@{
        pid = $PID
        started_at = (Get-Date).ToUniversalTime().ToString('o')
        host = [System.Net.Dns]::GetHostName()
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
        }
        finally {
            $stream.Dispose()
        }

        return [pscustomobject]@{
            acquired = $true
            paths = $state.paths
        }
    }
    catch [System.IO.IOException] {
        return [pscustomobject]@{
            acquired = $false
            paths = $state.paths
        }
    }
}

function Release-MissionControlHeartbeatQueueLock {
    param(
        [Parameter(Mandatory = $true)]$QueuePaths
    )

    if (Test-Path -LiteralPath $QueuePaths.lock) {
        Remove-Item -LiteralPath $QueuePaths.lock -Force
    }
}

function Get-MissionControlHeartbeatQueueItemId {
    param(
        [Parameter(Mandatory = $true)]$DispatchState
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
    if (-not $safeReason) {
        $safeReason = 'dispatch'
    }

    return "dispatch-$safeReason"
}

function Add-MissionControlHeartbeatQueueItem {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$InvocationAgent,
        [Parameter(Mandatory = $true)]$DispatchState
    )

    $paths = Ensure-MissionControlHeartbeatQueue -WorkspacePath $WorkspacePath
    $queueItemId = Get-MissionControlHeartbeatQueueItemId -DispatchState $DispatchState
    $pendingPath = Join-Path $paths.pending "$queueItemId.json"
    $processingPath = Join-Path $paths.processing "$queueItemId.json"

    if ((Test-Path -LiteralPath $pendingPath) -or (Test-Path -LiteralPath $processingPath)) {
        return $false
    }

    $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
    $queueItem = [ordered]@{
        queue_item_id = $queueItemId
        enqueued_at = (Get-Date).ToUniversalTime().ToString('o')
        invocation_agent = $InvocationAgent
        session_key = Get-OpenClawTaskSessionKey -InvocationAgent $InvocationAgent -DispatchState $DispatchState
        dispatch_state = $DispatchState
    }

    if ($firstTask -and $firstTask.id) {
        $queueItem.task_id = $firstTask.id
        $queueItem.task_status = $firstTask.status
    }

    $queueItem | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $pendingPath -Encoding UTF8
    return $true
}

function Start-MissionControlHeartbeatQueueProcessor {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $state = Get-MissionControlHeartbeatQueueLockState -WorkspacePath $WorkspacePath
    if ($state.active) {
        return $false
    }

    $pendingItems = @(
        Get-ChildItem -LiteralPath $state.paths.pending -Filter '*.json' -File -ErrorAction SilentlyContinue
    )
    if ($pendingItems.Count -eq 0) {
        return $false
    }

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    Start-Process `
        -FilePath $pwshPath `
        -ArgumentList @('-NoProfile', '-File', $ScriptPath, '-ProcessQueue') `
        -WorkingDirectory $state.paths.workflow `
        -RedirectStandardOutput $state.paths.stdoutLog `
        -RedirectStandardError $state.paths.stderrLog | Out-Null

    return $true
}

function Invoke-MissionControlHeartbeatQueueProcessor {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$InvocationAgent,
        [int]$TimeoutSec = 120
    )

    $lockState = Try-Acquire-MissionControlHeartbeatQueueLock -WorkspacePath $WorkspacePath
    if (-not $lockState.acquired) {
        return $false
    }

    try {
        while ($true) {
            $nextItem = @(
                Get-ChildItem -LiteralPath $lockState.paths.pending -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime, Name |
                    Select-Object -First 1
            )
            if ($nextItem.Count -eq 0) {
                break
            }

            $pendingItem = $nextItem[0]
            $processingPath = Join-Path $lockState.paths.processing $pendingItem.Name
            Move-Item -LiteralPath $pendingItem.FullName -Destination $processingPath -Force

            $queueItem = $null
            try {
                $queueItem = Get-Content -LiteralPath $processingPath -Raw | ConvertFrom-Json -Depth 50
                [void](Invoke-MissionControlHeartbeatAgent `
                    -WorkspacePath $WorkspacePath `
                    -InvocationAgent $InvocationAgent `
                    -DispatchState $queueItem.dispatch_state `
                    -TimeoutSec $TimeoutSec)

                Remove-Item -LiteralPath $processingPath -Force
            }
            catch {
                $failurePath = Join-Path $lockState.paths.failed $pendingItem.Name
                $failureRecord = [ordered]@{
                    failed_at = (Get-Date).ToUniversalTime().ToString('o')
                    error = ($_ | Out-String).Trim()
                    queue_item = $queueItem
                }
                $failureRecord | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $failurePath -Encoding UTF8

                if (Test-Path -LiteralPath $processingPath) {
                    Remove-Item -LiteralPath $processingPath -Force
                }
            }
        }

        return $true
    }
    finally {
        Release-MissionControlHeartbeatQueueLock -QueuePaths $lockState.paths
    }
}
