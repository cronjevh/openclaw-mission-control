#!/usr/bin/env pwsh
param(
    [switch]$KeepWorkspace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$helperPath = Join-Path $scriptRoot 'openclaw-heartbeat-session.ps1'
if (-not (Test-Path -LiteralPath $helperPath)) {
    throw "Heartbeat helper not found at $helperPath"
}

. $helperPath

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mc-heartbeat-queue-smoke-" + [guid]::NewGuid().Guid)
$workspacePath = Join-Path $testRoot 'workspace-lead-test'
$workflowPath = Join-Path $workspacePath '.openclaw/workflows'
$processedLogPath = Join-Path $testRoot 'processed.log'

New-Item -ItemType Directory -Path $workflowPath -Force | Out-Null
$script:ProcessedLogPath = $processedLogPath

function Invoke-MissionControlHeartbeatAgent {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$InvocationAgent,
        [Parameter(Mandatory = $true)]$DispatchState,
        [int]$TimeoutSec = 120
    )

    $firstTask = @($DispatchState.tasks | Where-Object { $_ -and $_.id }) | Select-Object -First 1
    $record = [ordered]@{
        invocation_agent = $InvocationAgent
        task_id = if ($firstTask) { [string]$firstTask.id } else { $null }
        task_status = if ($firstTask) { [string]$firstTask.status } else { $null }
        timeout_sec = $TimeoutSec
    }

    Add-Content -LiteralPath $script:ProcessedLogPath -Value (($record | ConvertTo-Json -Compress))
    return ($record | ConvertTo-Json -Compress)
}

function New-TestDispatchState {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$TaskStatus,
        [Parameter(Mandatory = $true)][string]$TaskTitle
    )

    return [pscustomobject]@{
        act = $true
        reason = 'smoke_test'
        agentRole = 'lead'
        boardId = 'test-board'
        agentId = 'test-board'
        summary = [pscustomobject]@{
            review = $TaskStatus -eq 'review'
            inbox = $TaskStatus -eq 'inbox'
        }
        tasks = @(
            [pscustomobject]@{
                id = $TaskId
                status = $TaskStatus
                title = $TaskTitle
            }
        )
    }
}

try {
    $dispatchStates = @(
        (New-TestDispatchState -TaskId '00000000-0000-0000-0000-000000000001' -TaskStatus 'inbox' -TaskTitle 'Smoke test inbox task'),
        (New-TestDispatchState -TaskId '00000000-0000-0000-0000-000000000002' -TaskStatus 'review' -TaskTitle 'Smoke test review task')
    )

    foreach ($dispatchState in $dispatchStates) {
        $added = Add-MissionControlHeartbeatQueueItem `
            -WorkspacePath $workspacePath `
            -InvocationAgent 'lead-test-board' `
            -DispatchState $dispatchState
        if (-not $added) {
            throw "Failed to enqueue task $((@($dispatchState.tasks)[0]).id)"
        }
    }

    $processed = Invoke-MissionControlHeartbeatQueueProcessor `
        -WorkspacePath $workspacePath `
        -InvocationAgent 'lead-test-board' `
        -TimeoutSec 5
    if (-not $processed) {
        throw 'Queue processor did not acquire the queue lock'
    }

    $queuePaths = Get-MissionControlHeartbeatQueuePaths -WorkspacePath $workspacePath
    $pendingCount = @(Get-ChildItem -LiteralPath $queuePaths.pending -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $processingCount = @(Get-ChildItem -LiteralPath $queuePaths.processing -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $failedCount = @(Get-ChildItem -LiteralPath $queuePaths.failed -Filter '*.json' -File -ErrorAction SilentlyContinue).Count

    if ($pendingCount -ne 0) {
        throw "Expected 0 pending queue items, found $pendingCount"
    }
    if ($processingCount -ne 0) {
        throw "Expected 0 processing queue items, found $processingCount"
    }
    if ($failedCount -ne 0) {
        throw "Expected 0 failed queue items, found $failedCount"
    }
    if (-not (Test-Path -LiteralPath $processedLogPath)) {
        throw 'Processed log was not created'
    }

    $processedLines = @(Get-Content -LiteralPath $processedLogPath | Where-Object { $_.Trim() })
    if ($processedLines.Count -ne 2) {
        throw "Expected 2 processed queue entries, found $($processedLines.Count)"
    }

    $processedTaskIds = @(
        $processedLines |
            ForEach-Object { $_ | ConvertFrom-Json } |
            ForEach-Object { [string]$_.task_id }
    )
    foreach ($expectedTaskId in @('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002')) {
        if ($processedTaskIds -notcontains $expectedTaskId) {
            throw "Processed log is missing task $expectedTaskId"
        }
    }

    Write-Host 'PASS # heartbeat queue smoke test'
    Write-Host "workspace=$workspacePath"
    Write-Host "processed_log=$processedLogPath"
}
finally {
    if (-not $KeepWorkspace -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
