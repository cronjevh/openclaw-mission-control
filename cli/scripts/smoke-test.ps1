#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Smoke tests for mcon CLI. Validates argument parsing and error handling.
.DESCRIPTION
    These tests exercise the CLI surface without requiring a live API.
    They verify: usage errors, validation errors, help output.
    For live API tests, set MCON_BASE_URL, MCON_AUTH_TOKEN, MCON_BOARD_ID.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Set dummy env to avoid keybag loading and allow validation tests
$env:MCON_AUTH_TOKEN = 'dummy'
$env:MCON_BASE_URL = 'http://localhost:9999'
$env:MCON_BOARD_ID = '00000000-0000-0000-0000-000000000000'
$env:MCON_WSP = 'workspace-gateway-test'

$mconScript = Join-Path $PSScriptRoot 'mcon.ps1'
$configModule = Join-Path $PSScriptRoot 'lib/Config.psm1'
$heartbeatModule = Join-Path $PSScriptRoot 'lib/Heartbeat.psm1'
$dispatchModule = Join-Path $PSScriptRoot 'lib/Dispatch.psm1'
$assignModule = Join-Path $PSScriptRoot 'lib/Assign.psm1'
$passCount = 0
$failCount = 0

function Assert-ExitCode {
    param(
        [string]$Label,
        [int]$Expected,
        [int]$Actual
    )
    if ($Expected -eq $Actual) {
        $script:passCount++
    } else {
        Write-Host "FAIL: $Label - expected exit $Expected, got $Actual"
        $script:failCount++
    }
}

function Assert-OutputContains {
    param(
        [string]$Label,
        [string]$Output,
        [string]$Expected
    )
    if ($Output -match [regex]::Escape($Expected)) {
        $script:passCount++
    } else {
        Write-Host "FAIL: $Label - expected output to contain '$Expected'"
        $script:failCount++
    }
}

Import-Module $configModule -Force
Import-Module $heartbeatModule -Force
Import-Module $dispatchModule -Force
Import-Module $assignModule -Force

# Test: verifier dispatch states use verify routing and a stable session key
$verifierTaskId = '11111111-1111-1111-1111-111111111111'
$verifierDispatch = [pscustomobject]@{
    act       = $true
    reason    = 'verifier_review'
    agentRole = 'verifier'
    boardId   = '00000000-0000-0000-0000-000000000000'
    agentId   = 'abc123'
    summary   = [ordered]@{ review = $true }
    tasks     = @(
        [pscustomobject]@{
            id                    = $verifierTaskId
            status                = 'review'
            title                 = 'Verifier task'
            task_data_path        = '/tmp/taskData.json'
            task_directory        = '/tmp/task'
            deliverables_directory = '/tmp/task/deliverables'
            evidence_directory    = '/tmp/task/evidence'
        }
    )
}
$verifierStates = @(Get-MconHeartbeatDispatchStates -DispatchResult $verifierDispatch)
if ($verifierStates.Count -eq 1) {
    $passCount++
} else {
    Write-Host "FAIL: verifier-dispatch-count - expected 1 dispatch state, got $($verifierStates.Count)"
    $failCount++
}

if ($verifierStates[0].dispatch_type -eq 'verify') {
    $passCount++
} else {
    Write-Host "FAIL: verifier-dispatch-type - expected 'verify', got '$($verifierStates[0].dispatch_type)'"
    $failCount++
}

$verifierSessionKey = Get-MconTaskSessionKey -InvocationAgent 'mc-abc123' -DispatchState $verifierStates[0]
if ($verifierSessionKey -eq "agent:mc-abc123:task:$verifierTaskId") {
    $passCount++
} else {
    Write-Host "FAIL: verifier-session-key - expected 'agent:mc-abc123:task:$verifierTaskId', got '$verifierSessionKey'"
    $failCount++
}

# Test: assignment origin session keys normalize from heartbeat envelopes
$assignTaskId = '33333333-3333-3333-3333-333333333333'
$assignTagId = '44444444-4444-4444-4444-444444444444'
$assignHeartbeatTaskKey = "agent:lead-testboard:task:$assignTaskId"
$assignHeartbeatTagKey = "agent:lead-testboard:tag:$assignTagId"

$normalizedTaskKey = ConvertTo-MconCanonicalAssignmentSessionKey -OriginSessionKey $assignHeartbeatTaskKey
if ($normalizedTaskKey -eq "task:$assignTaskId") {
    $passCount++
} else {
    Write-Host "FAIL: assign-origin-normalize-task - expected 'task:$assignTaskId', got '$normalizedTaskKey'"
    $failCount++
}

$normalizedTagKey = ConvertTo-MconCanonicalAssignmentSessionKey -OriginSessionKey $assignHeartbeatTagKey
if ($normalizedTagKey -eq "tag:$assignTagId") {
    $passCount++
} else {
    Write-Host "FAIL: assign-origin-normalize-tag - expected 'tag:$assignTagId', got '$normalizedTagKey'"
    $failCount++
}

$assignRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mcon-assign-smoke-" + [guid]::NewGuid().Guid)
$assignLeadWorkspace = Join-Path $assignRoot 'workspace-lead-smoke'
$assignWorkerWorkspace = Join-Path $assignRoot 'workspace-mc-466803cc-1793-45e6-9dc0-437c505d49b4'
New-Item -ItemType Directory -Path $assignLeadWorkspace -Force | Out-Null
New-Item -ItemType Directory -Path $assignWorkerWorkspace -Force | Out-Null
try {
    $openClawConfigPath = Join-Path $assignRoot 'openclaw.json'
    $openClawFixture = [ordered]@{
        agents = [ordered]@{
            list = @(
                [ordered]@{
                    id = 'mc-466803cc-1793-45e6-9dc0-437c505d49b4'
                    name = 'Vulcan'
                    workspace = $assignWorkerWorkspace
                }
            )
        }
    }
    $openClawFixture | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $openClawConfigPath -Encoding UTF8

    $assignWorkflowTaskId = '55555555-5555-5555-5555-555555555555'
    $assignBoardId = '00000000-0000-0000-0000-000000000000'
    $assignTask = [pscustomobject]@{
        id                    = $assignWorkflowTaskId
        title                 = 'Frontend change - change board display so that task in Done column are sorted by date completed descending'
        description           = $null
        status                = 'inbox'
        priority              = 'medium'
        due_at                = $null
        assigned_agent_id     = $null
        closure_mode          = $null
        required_artifact_kinds = @()
        required_check_kinds  = @()
        lead_spot_check_required = $false
        depends_on_task_ids    = @()
        blocked_by_task_ids    = @()
        is_blocked             = $false
        tag_ids                = @('684ddc69-de7f-4864-9b1a-323fa7cc81a4')
        tags                   = @(
            [pscustomobject]@{
                id    = '684ddc69-de7f-4864-9b1a-323fa7cc81a4'
                name  = 'Project Mission Control Development'
                slug  = 'project-mission-control-development'
                color = '419e9e'
            }
        )
        custom_field_values    = [ordered]@{
            subagent_uuid = $null
            backlog       = $false
        }
        board_id               = $assignBoardId
        created_at             = '2026-04-21T15:38:28.29008'
        updated_at             = '2026-04-21T15:38:28.290089'
    }

    function Invoke-MconApi {
        param(
            [Parameter(Mandatory)][string]$Method,
            [Parameter(Mandatory)][string]$Uri,
            [Parameter(Mandatory)][string]$Token,
            $Body = $null
        )

        if ($Method -eq 'Get' -and $Uri -like '*/comments') {
            return [pscustomobject]@{ items = @() }
        }
        if ($Method -eq 'Get') {
            return $assignTask
        }
        throw "Unexpected Invoke-MconApi call in smoke test: $Method $Uri"
    }

    $assignConfig = [ordered]@{
        base_url    = 'http://localhost:9999'
        auth_token  = 'dummy'
        board_id    = $assignBoardId
        workspace_path = $assignLeadWorkspace
        wsp         = 'workspace-lead-smoke'
        agent_id    = 'lead-smoke'
    }
    $assignResult = Invoke-MconAssign `
        -Config $assignConfig `
        -TaskId $assignWorkflowTaskId `
        -WorkerAgentId '466803cc-1793-45e6-9dc0-437c505d49b4' `
        -OriginSessionKey "task:$assignWorkflowTaskId" `
        -WorkerWorkspacePath $assignWorkerWorkspace `
        -LeadAgentId 'lead-smoke' `
        -BundleOnly

    if (
        $assignResult.ok -eq $true -and
        $assignResult.workerSpawnAgentId -eq 'mc-466803cc-1793-45e6-9dc0-437c505d49b4' -and
        $assignResult.workerLegacyAgentName -eq 'vulcan' -and
        (Test-Path -LiteralPath $assignResult.bundlePath) -and
        (Test-Path -LiteralPath $assignResult.workerTaskDataPath)
    ) {
        $passCount++
    } else {
        Write-Host "FAIL: assign-spawn-agent-id - expected canonical worker agent id 'mc-466803cc-1793-45e6-9dc0-437c505d49b4', got '$($assignResult.workerSpawnAgentId)'"
        $failCount++
    }
} finally {
    Remove-Item Function:Invoke-MconApi -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $assignLeadWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $assignWorkerWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $assignRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$queueSmokeWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ("mcon-queue-smoke-" + [guid]::NewGuid().Guid)
New-Item -ItemType Directory -Path $queueSmokeWorkspace -Force | Out-Null
try {
    $queueTaskId = '22222222-2222-2222-2222-222222222222'
    $queueDispatchState = [pscustomobject]@{
        act            = $true
        reason         = 'smoke'
        dispatch_type  = 'heartbeat'
        agentRole      = 'worker'
        boardId        = '00000000-0000-0000-0000-000000000000'
        agentId        = 'abc123'
        summary        = [ordered]@{}
        tasks          = @(
            [pscustomobject]@{
                id                     = $queueTaskId
                status                 = 'inbox'
                title                  = 'Queue smoke task'
                task_data_path         = '/tmp/taskData.json'
                task_directory         = '/tmp/task'
                deliverables_directory  = '/tmp/task/deliverables'
                evidence_directory      = '/tmp/task/evidence'
            }
        )
    }

    $firstQueueResult = Add-MconHeartbeatQueueItem -WorkspacePath $queueSmokeWorkspace -InvocationAgent 'mc-abc123' -DispatchState $queueDispatchState
    if ($firstQueueResult -eq 'queued') {
        $passCount++
    } else {
        Write-Host "FAIL: queue-first-enqueue - expected 'queued', got '$firstQueueResult'"
        $failCount++
    }

    $secondQueueResult = Add-MconHeartbeatQueueItem -WorkspacePath $queueSmokeWorkspace -InvocationAgent 'mc-abc123' -DispatchState $queueDispatchState
    if ($secondQueueResult -eq 'already_pending') {
        $passCount++
    } else {
        Write-Host "FAIL: queue-idempotent-enqueue - expected 'already_pending', got '$secondQueueResult'"
        $failCount++
    }

    $queuePaths = Get-MconHeartbeatQueuePaths -WorkspacePath $queueSmokeWorkspace
    $pendingCount = @(Get-ChildItem -LiteralPath $queuePaths.pending -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    if ($pendingCount -eq 1) {
        $passCount++
    } else {
        Write-Host "FAIL: queue-pending-count - expected 1 pending item, got $pendingCount"
        $failCount++
    }

    Remove-Item -LiteralPath (Join-Path $queuePaths.pending "$queueTaskId.json") -Force
    $recentFailurePath = Join-Path $queuePaths.failed "$queueTaskId-failure-recent.json"
    Set-Content -LiteralPath $recentFailurePath -Value '{"error":"recent failure"}' -Encoding UTF8
    (Get-Item -LiteralPath $recentFailurePath).LastWriteTime = Get-Date

    $cooldownQueueResult = Add-MconHeartbeatQueueItem -WorkspacePath $queueSmokeWorkspace -InvocationAgent 'mc-abc123' -DispatchState $queueDispatchState
    if ($cooldownQueueResult -eq 'cooldown') {
        $passCount++
    } else {
        Write-Host "FAIL: queue-cooldown-gate - expected 'cooldown', got '$cooldownQueueResult'"
        $failCount++
    }

    (Get-Item -LiteralPath $recentFailurePath).LastWriteTime = (Get-Date).AddMinutes(-20)
    $retryQueueResult = Add-MconHeartbeatQueueItem -WorkspacePath $queueSmokeWorkspace -InvocationAgent 'mc-abc123' -DispatchState $queueDispatchState
    if ($retryQueueResult -eq 'queued') {
        $passCount++
    } else {
        Write-Host "FAIL: queue-cooldown-expiry - expected 'queued', got '$retryQueueResult'"
        $failCount++
    }

    $restoredSource = Join-Path $queuePaths.processing 'stale.json'
    Set-Content -LiteralPath $restoredSource -Value '{}' -Encoding UTF8
    Restore-MconHeartbeatProcessingQueue -QueuePaths $queuePaths
    if ((Test-Path -LiteralPath (Join-Path $queuePaths.pending 'stale.json')) -and (-not (Test-Path -LiteralPath $restoredSource))) {
        $passCount++
    } else {
        Write-Host 'FAIL: queue-restore-processing - expected processing item to move back to pending'
        $failCount++
    }

    $staleSource = Join-Path $queuePaths.processing 'old.json'
    Set-Content -LiteralPath $staleSource -Value '{}' -Encoding UTF8
    (Get-Item -LiteralPath $staleSource).LastWriteTime = (Get-Date).AddMinutes(-30)
    $staleCount = Clear-MconHeartbeatStuckProcessingItems -QueuePaths $queuePaths -MaxProcessingMinutes 10
    $staleFailed = @(Get-ChildItem -LiteralPath $queuePaths.failed -Filter 'old-stale-*.json' -File -ErrorAction SilentlyContinue).Count
    if ($staleCount -eq 1 -and $staleFailed -eq 1 -and (-not (Test-Path -LiteralPath $staleSource))) {
        $passCount++
    } else {
        Write-Host "FAIL: queue-stale-processing - expected 1 stale item moved to failed, got count=$staleCount failed=$staleFailed"
        $failCount++
    }

    $fakeMconScript = Join-Path $queueSmokeWorkspace 'mcon.ps1'
    $fakeMconScriptContent = @'
$launchId = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--processor-launch-id' -and ($i + 1) -lt $args.Count) {
        $launchId = $args[$i + 1]
        break
    }
}
if ([string]::IsNullOrWhiteSpace($launchId)) {
    throw 'missing --processor-launch-id'
}

$workspace = (Get-Location).Path
$queueRoot = Join-Path $workspace '.openclaw/workflows/mc-board-heartbeat-queue'
$runDir = Join-Path $queueRoot 'processor-runs'
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$envSnapshot = [ordered]@{
    MCON_AUTH_TOKEN = $env:MCON_AUTH_TOKEN
    MCON_BASE_URL   = $env:MCON_BASE_URL
    MCON_BOARD_ID   = $env:MCON_BOARD_ID
    MCON_AGENT_ID   = $env:MCON_AGENT_ID
    MCON_WSP        = $env:MCON_WSP
}
$envSnapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $queueRoot 'launch-env.json') -Encoding UTF8

$state = [ordered]@{
    launch_id  = $launchId
    state      = 'started'
    updated_at = (Get-Date).ToUniversalTime().ToString('o')
    pid        = $PID
}
$json = $state | ConvertTo-Json -Depth 10
$json | Set-Content -LiteralPath (Join-Path $runDir "$launchId.json") -Encoding UTF8
$json | Set-Content -LiteralPath (Join-Path $queueRoot 'processor.latest.json') -Encoding UTF8
'@
    Set-Content -LiteralPath $fakeMconScript -Value $fakeMconScriptContent -Encoding UTF8

    $started = Start-MconHeartbeatQueueProcessor -WorkspacePath $queueSmokeWorkspace -MconScriptPath $fakeMconScript -StartupTimeoutSec 5
    $envSnapshotPath = Join-Path $queuePaths.root 'launch-env.json'
    $envSnapshot = if (Test-Path -LiteralPath $envSnapshotPath) {
        Get-Content -LiteralPath $envSnapshotPath -Raw | ConvertFrom-Json
    } else {
        $null
    }
    $unscrubbedIdentityCount = [int]::MaxValue
    if ($envSnapshot) {
        $unscrubbedIdentityCount = 0
        foreach ($name in @('MCON_AUTH_TOKEN', 'MCON_BASE_URL', 'MCON_BOARD_ID', 'MCON_AGENT_ID', 'MCON_WSP')) {
            if (-not [string]::IsNullOrEmpty([string]$envSnapshot.$name)) {
                $unscrubbedIdentityCount++
            }
        }
    }

    if ($started.launched -eq $true -and $started.confirmed_started -eq $true -and $unscrubbedIdentityCount -eq 0) {
        $passCount++
    } else {
        Write-Host 'FAIL: queue-start-process - expected detached processor launch with scrubbed identity environment'
        $failCount++
    }
} finally {
    Remove-Item -LiteralPath $queueSmokeWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

$dispatchSmokeWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ("mcon-dispatch-smoke-" + [guid]::NewGuid().Guid)
New-Item -ItemType Directory -Path $dispatchSmokeWorkspace -Force | Out-Null
try {
    $dispatchResult = New-MconDispatchResult -Act $false -Reason 'idle' -AgentRole 'lead' -BoardId '00000000-0000-0000-0000-000000000000' -AgentId 'abc123' -Summary ([ordered]@{ paused = $false; inbox = $false; assignedInbox = $false; assignedInProgress = $false; review = $false }) -Tasks @()
    $dispatchResult.tasks = @(
        [ordered]@{
            id                     = 'task-1'
            status                 = 'inbox'
            title                  = 'Task One'
            subagent_uuid          = 'sub-1'
            task_data_path         = '/tmp/taskData.json'
            task_directory         = '/tmp/task'
            deliverables_directory = '/tmp/task/deliverables'
            evidence_directory     = '/tmp/task/evidence'
            comments               = @(
                [ordered]@{
                    id = 'comment-1'
                    created_at = '2026-04-21T12:00:00Z'
                    agent_id = 'abc123'
                    agent_name = 'Vulcan'
                    author_name = 'Vulcan'
                    message = 'cache smoke comment'
                }
            )
            task_data              = [ordered]@{
                task = [ordered]@{
                    id = 'task-1'
                    title = 'Task One'
                }
                comments = @(
                    [ordered]@{
                        id = 'comment-1'
                        message = 'cache smoke comment'
                    }
                )
                boardWorkers = @(
                    [ordered]@{ id = 'worker-1'; name = 'Hermes' }
                )
            }
        }
    )
    Write-MconDispatchState -WorkspacePath $dispatchSmokeWorkspace -DispatchResult $dispatchResult | Out-Null

    $dispatchStatePath = Join-Path (Join-Path $dispatchSmokeWorkspace '.openclaw/workflows') '.dispatch-state-latest.json'
    if (Test-Path -LiteralPath $dispatchStatePath) {
        $dispatchState = Get-Content -LiteralPath $dispatchStatePath -Raw | ConvertFrom-Json -Depth 20
        $schemaChecks = @(
            $dispatchState.ttl_seconds -eq 300
            $dispatchState.gate_version -eq '1.0.0'
            $dispatchState.board_id -eq '00000000-0000-0000-0000-000000000000'
            $dispatchState.agent_id -eq 'abc123'
            $dispatchState.agent_role -eq 'lead'
            $dispatchState.act -eq $false
            $dispatchState.reason -eq 'idle'
            @($dispatchState.tasks).Count -eq 1
            $dispatchState.tasks[0].task_data.task.title -eq 'Task One'
            @($dispatchState.tasks[0].task_data.comments).Count -eq 1
            $dispatchState.tasks[0].task_data.comments[0].message -eq 'cache smoke comment'
        )

        if (@($schemaChecks | Where-Object { $_ -ne $true }).Count -eq 0) {
            $passCount++
        } else {
            Write-Host 'FAIL: dispatch-state-schema - cache file missing expected fields or values'
            $failCount++
        }
    } else {
        Write-Host 'FAIL: dispatch-state-written - expected .dispatch-state-latest.json to be created by writer'
        $failCount++
    }
} finally {
    Remove-Item -LiteralPath $dispatchSmokeWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '=== mcon smoke tests ==='
Write-Host ''

# Test: no args -> usage error
$out = pwsh -NoProfile -File $mconScript 2>&1
Assert-ExitCode -Label 'no-args-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'no-args-json' -Output ($out -join '') -Expected '"ok":false'

# Test: unknown subcommand
$out = pwsh -NoProfile -File $mconScript foo 2>&1
Assert-ExitCode -Label 'unknown-cmd-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'unknown-cmd-error' -Output ($out -join '') -Expected 'Unknown subcommand'

# Test: help
$out = pwsh -NoProfile -File $mconScript help 2>&1
Assert-ExitCode -Label 'help-exit0' -Expected 0 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'help-content' -Output ($out -join '') -Expected 'task show'

# Test: task without action
$out = pwsh -NoProfile -File $mconScript task 2>&1
Assert-ExitCode -Label 'task-no-action-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'task-no-action-error' -Output ($out -join '') -Expected 'task <action>'

# Test: task show without selector
$out = pwsh -NoProfile -File $mconScript task show 2>&1
Assert-ExitCode -Label 'show-no-task-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'show-no-task-error' -Output ($out -join '') -Expected 'requires either'

# Test: task show with invalid UUID
$out = pwsh -NoProfile -File $mconScript task show --task not-a-uuid 2>&1
Assert-ExitCode -Label 'show-bad-uuid-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'show-bad-uuid-error' -Output ($out -join '') -Expected 'Invalid task ID'

# Test: task show with both --task and --tags
$out = pwsh -NoProfile -File $mconScript task show --task 00000000-0000-0000-0000-000000000001 --tags project-mission-control-mechanics 2>&1
Assert-ExitCode -Label 'show-task-and-tags-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'show-task-and-tags-error' -Output ($out -join '') -Expected 'either --task'

# Test: task show with tags reaches API layer
$out = pwsh -NoProfile -File $mconScript task show --tags project-mission-control-mechanics 2>&1
Assert-ExitCode -Label 'show-tags-api-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'show-tags-api-error' -Output ($out -join '') -Expected 'api_error'

# Test: task comment without --message
$out = pwsh -NoProfile -File $mconScript task comment --task 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'comment-no-msg-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'comment-no-msg-error' -Output ($out -join '') -Expected 'required'

# Test: task move without --status
$out = pwsh -NoProfile -File $mconScript task move --task 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'move-no-status-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'move-no-status-error' -Output ($out -join '') -Expected 'required'

# Test: task move with invalid status
$out = pwsh -NoProfile -File $mconScript task move --task 00000000-0000-0000-0000-000000000001 --status flying 2>&1
Assert-ExitCode -Label 'move-bad-status-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'move-bad-status-error' -Output ($out -join '') -Expected 'Invalid status'

# Test: unknown flag
$out = pwsh -NoProfile -File $mconScript task show --task 00000000-0000-0000-0000-000000000001 --bogus 2>&1
Assert-ExitCode -Label 'unknown-flag-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'unknown-flag-error' -Output ($out -join '') -Expected 'Unknown flag'

# Test: verify without action
$out = pwsh -NoProfile -File $mconScript verify 2>&1
Assert-ExitCode -Label 'verify-no-action-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'verify-no-action-error' -Output ($out -join '') -Expected 'verify <action>'

# Test: verify run without --task
$out = pwsh -NoProfile -File $mconScript verify run 2>&1
Assert-ExitCode -Label 'verify-run-no-task-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'verify-run-no-task-error' -Output ($out -join '') -Expected 'required'

# Test: workflow blocker without --task
$out = pwsh -NoProfile -File $mconScript workflow blocker --message blocked 2>&1
Assert-ExitCode -Label 'blocker-no-task-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'blocker-no-task-error' -Output ($out -join '') -Expected 'required'

# Test: workflow blocker without --message
$out = pwsh -NoProfile -File $mconScript workflow blocker --task 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'blocker-no-message-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'blocker-no-message-error' -Output ($out -join '') -Expected 'required'

# Test: workflow assign without origin session key
$out = pwsh -NoProfile -Command "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='workspace-lead-testboard'; & '$mconScript' workflow assign --task 00000000-0000-0000-0000-000000000001 --worker 11111111-1111-1111-1111-111111111111" 2>&1
Assert-ExitCode -Label 'assign-no-origin-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'assign-no-origin-error' -Output ($out -join '') -Expected 'origin session key'

# Test: workflow escalate without --message
$out = pwsh -NoProfile -File $mconScript workflow escalate 2>&1
Assert-ExitCode -Label 'escalate-no-message-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'escalate-no-message-error' -Output ($out -join '') -Expected 'required'

# Test: workflow escalate with target agent but no secret key
$out = pwsh -NoProfile -File $mconScript workflow escalate --message blocked --target-agent 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'escalate-target-without-secret-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'escalate-target-without-secret-error' -Output ($out -join '') -Expected 'require --secret-key'

# Test: workflow escalate with channel and secret key
$out = pwsh -NoProfile -File $mconScript workflow escalate --message blocked --secret-key GITHUB_TOKEN --channel chat 2>&1
Assert-ExitCode -Label 'escalate-secret-with-channel-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'escalate-secret-with-channel-error' -Output ($out -join '') -Expected 'only valid'

# Test: task create with invalid tag ID
$out = pwsh -NoProfile -File $mconScript task create --title 'test' --tags not-a-uuid 2>&1
Assert-ExitCode -Label 'create-bad-tag-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'create-bad-tag-error' -Output ($out -join '') -Expected 'API error'

# Test: task create with invalid depends-on ID
$out = pwsh -NoProfile -File $mconScript task create --title 'test' --depends-on not-a-uuid 2>&1
Assert-ExitCode -Label 'create-bad-dep-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'create-bad-dep-error' -Output ($out -join '') -Expected 'Invalid depends-on task ID'

# Test: task create with valid tags and depends-on (passes validation, fails at API)
$out = pwsh -NoProfile -File $mconScript task create --title 'test' --tags 11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222 --depends-on 33333333-3333-3333-3333-333333333333 2>&1
Assert-ExitCode -Label 'create-valid-tags-deps-api-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'create-valid-tags-deps-api-error' -Output ($out -join '') -Expected 'API error'

# Test: task update without --task
$out = pwsh -NoProfile -File $mconScript task update --title 'new' 2>&1
Assert-ExitCode -Label 'update-no-task-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-no-task-error' -Output ($out -join '') -Expected 'required'

# Test: task update without any update fields
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'update-no-fields-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-no-fields-error' -Output ($out -join '') -Expected 'At least one update field'

# Test: task update with invalid tag ID
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 --tags bad-uuid 2>&1
Assert-ExitCode -Label 'update-bad-tag-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-bad-tag-error' -Output ($out -join '') -Expected 'API error'

# Test: task update with invalid depends-on ID
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 --depends-on bad-uuid 2>&1
Assert-ExitCode -Label 'update-bad-dep-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-bad-dep-error' -Output ($out -join '') -Expected 'Invalid depends-on task ID'

# Test: task update with valid fields (passes validation, fails at API)
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 --title 'new' --priority high 2>&1
Assert-ExitCode -Label 'update-valid-api-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-valid-api-error' -Output ($out -join '') -Expected 'api_error'

# Test: task update with --backlog invalid value
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 --backlog maybe 2>&1
Assert-ExitCode -Label 'update-bad-backlog-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-bad-backlog-error' -Output ($out -join '') -Expected "must be 'true' or 'false'"

# Test: admin cron without --board-id
$out = pwsh -NoProfile -File $mconScript admin cron --cadence-minutes 10 2>&1
Assert-ExitCode -Label 'cron-no-board-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'cron-no-board-error' -Output ($out -join '') -Expected '--board-id'

# Test: admin cron without --cadence-minutes
$out = pwsh -NoProfile -File $mconScript admin cron --board-id 00000000-0000-0000-0000-000000000000 2>&1
Assert-ExitCode -Label 'cron-no-cadence-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'cron-no-cadence-error' -Output ($out -join '') -Expected '--cadence-minutes'

# Test: admin cron with invalid board-id
$out = pwsh -NoProfile -File $mconScript admin cron --board-id not-a-uuid --cadence-minutes 10 2>&1
Assert-ExitCode -Label 'cron-bad-board-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'cron-bad-board-error' -Output ($out -join '') -Expected 'Invalid board ID'

# Test: admin cron with non-integer cadence
$out = pwsh -NoProfile -File $mconScript admin cron --board-id 00000000-0000-0000-0000-000000000000 --cadence-minutes abc 2>&1
Assert-ExitCode -Label 'cron-bad-cadence-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'cron-bad-cadence-error' -Output ($out -join '') -Expected 'must be an integer'

Write-Host ''
Write-Host "Results: $passCount passed, $failCount failed"

if ($failCount -gt 0) {
    exit 1
}
Write-Host 'All smoke tests passed.'

# --- Permission tests (require env vars) ---
Write-Host ''
Write-Host '=== mcon permission smoke tests ==='
Write-Host ''

# Helper function to run mcon with explicit env in a new process
function Invoke-MconProcess {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$Wsp = 'workspace-gateway-testgw'
    )
    $argString = $Arguments -join ' '
    $cmd = "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='$Wsp'; & '$mconScript' $argString"
    $out = pwsh -NoProfile -Command $cmd 2>&1
    return $out
}

# Test: worker denied task move
Write-Host '--- worker denied task move ---'
$out = Invoke-MconProcess -Arguments @('task','move','--task','00000000-0000-0000-0000-000000000001','--status','done') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-move-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-move-denied-msg' -Output $out -Expected 'Permission denied'

# Test: lead denied task move
Write-Host '--- lead denied task move ---'
$out = Invoke-MconProcess -Arguments @('task','move','--task','00000000-0000-0000-0000-000000000001','--status','done') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-move-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-move-denied-msg' -Output $out -Expected 'Permission denied'

# Test: gateway allowed task move (will fail at API but not at permission)
Write-Host '--- gateway passes permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('task','move','--task','00000000-0000-0000-0000-000000000001','--status','done') -Wsp 'workspace-gateway-testgw'
Assert-ExitCode -Label 'gateway-move-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'gateway-move-passes-perm' -Output $out -Expected 'Connection refused'

# Test: worker denied verify run
Write-Host '--- worker denied verify run ---'
$out = Invoke-MconProcess -Arguments @('verify','run','--task','00000000-0000-0000-0000-000000000001') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-verify-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-verify-denied-msg' -Output $out -Expected 'Permission denied'

# Test: worker allowed workflow blocker (will fail at API but not at permission)
Write-Host '--- worker passes workflow blocker permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('workflow','blocker','--task','00000000-0000-0000-0000-000000000001','--message','stuck') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-blocker-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-blocker-passes-perm' -Output $out -Expected 'Connection refused'

# Test: lead denied workflow blocker
Write-Host '--- lead denied workflow blocker ---'
$out = Invoke-MconProcess -Arguments @('workflow','blocker','--task','00000000-0000-0000-0000-000000000001','--message','needhelp') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-blocker-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-blocker-denied-msg' -Output $out -Expected 'Permission denied'

# Test: worker denied workflow escalate
Write-Host '--- worker denied workflow escalate ---'
$out = Invoke-MconProcess -Arguments @('workflow','escalate','--message','needhelp') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-escalate-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-escalate-denied-msg' -Output $out -Expected 'Permission denied'

# Test: lead allowed workflow escalate (API fails after permission)
Write-Host '--- lead passes workflow escalate permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('workflow','escalate','--message','needhelp') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-escalate-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-escalate-passes-perm' -Output $out -Expected 'Connection refused'

# Test: worker denied task update
Write-Host '--- worker denied task update ---'
$out = Invoke-MconProcess -Arguments @('task','update','--task','00000000-0000-0000-0000-000000000001','--title','new') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-update-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-update-denied-msg' -Output $out -Expected 'Permission denied'

# Test: lead allowed task update (API fails after permission)
Write-Host '--- lead passes task update permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('task','update','--task','00000000-0000-0000-0000-000000000001','--title','new') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-update-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-update-passes-perm' -Output $out -Expected 'Connection refused'

# Test: gateway allowed task update (API fails after permission)
Write-Host '--- gateway passes task update permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('task','update','--task','00000000-0000-0000-0000-000000000001','--title','new') -Wsp 'workspace-gateway-testgw'
Assert-ExitCode -Label 'gateway-update-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'gateway-update-passes-perm' -Output $out -Expected 'Connection refused'

# Test: missing MCON_WSP
Write-Host '--- missing MCON_WSP error ---'
$out = pwsh -NoProfile -Command "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; remove-item env:MCON_WSP -ErrorAction SilentlyContinue; & '/home/cronjev/mcon-cli/scripts/mcon.ps1' task show --task 00000000-0000-0000-0000-000000000001" 2>&1
Assert-ExitCode -Label 'missing-wsp-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'missing-wsp-error' -Output $out -Expected 'MCON_WSP'

# Test: unrecognized MCON_WSP prefix
Write-Host '--- unrecognized MCON_WSP prefix ---'
$out = pwsh -NoProfile -Command "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='workspace-unknown-foo'; & '/home/cronjev/mcon-cli/scripts/mcon.ps1' task show --task 00000000-0000-0000-0000-000000000001" 2>&1
Assert-ExitCode -Label 'bad-wsp-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'bad-wsp-error' -Output $out -Expected 'Cannot determine role'

# --- admin.gettokens permission tests ---
Write-Host ''
Write-Host '--- admin.gettokens permission tests ---'

# Test: worker denied admin.gettokens
Write-Host '--- worker denied admin.gettokens ---'
$out = Invoke-MconProcess -Arguments @('admin','gettokens') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-admin-deny' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-admin-msg' -Output $out -Expected 'Permission denied'

# Test: lead denied admin.gettokens
Write-Host '--- lead denied admin.gettokens ---'
$out = Invoke-MconProcess -Arguments @('admin','gettokens') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-admin-deny' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-admin-msg' -Output $out -Expected 'Permission denied'

# Test: gateway admin.gettokens allowed; succeeds if the backend is up, otherwise fails at API call
Write-Host '--- gateway admin.gettokens allowed (backend dependent) ---'
$out = Invoke-MconProcess -Arguments @('admin','gettokens') -Wsp 'workspace-gateway-testgw'
if ($LASTEXITCODE -eq 0) {
    Assert-OutputContains -Label 'gateway-admin-success' -Output $out -Expected '"action":"admin.gettokens"'
} else {
    Assert-ExitCode -Label 'gateway-admin-api-fail' -Expected 1 -Actual $LASTEXITCODE
    Assert-OutputContains -Label 'gateway-admin-api-fail-msg' -Output $out -Expected 'Connection refused'
}

# --- admin.cron permission tests ---
Write-Host ''
Write-Host '--- admin.cron permission tests ---'

# Test: worker denied admin.cron
Write-Host '--- worker denied admin.cron ---'
$out = Invoke-MconProcess -Arguments @('admin','cron','--board-id','00000000-0000-0000-0000-000000000000','--cadence-minutes','10') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-cron-deny' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-cron-msg' -Output $out -Expected 'Permission denied'

# Test: lead denied admin.cron
Write-Host '--- lead denied admin.cron ---'
$out = Invoke-MconProcess -Arguments @('admin','cron','--board-id','00000000-0000-0000-0000-000000000000','--cadence-minutes','10') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-cron-deny' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-cron-msg' -Output $out -Expected 'Permission denied'

Write-Host ''
Write-Host "Permission smoke results: $passCount passed, $failCount failed (total)"

if ($failCount -gt 0) {
    exit 1
}
Write-Host 'All smoke tests passed.'
