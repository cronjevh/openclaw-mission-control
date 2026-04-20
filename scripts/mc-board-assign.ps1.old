#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Canonical Mission Control worker handoff workflow.
.DESCRIPTION
    Performs the end-to-end lead handoff for one board task:
    - fetches live task state
    - assembles a deterministic bootstrap bundle
    - optionally spawns the worker subagent via the lead agent
    - patches task assignment + subagent UUID
    - patches task status to in_progress

    This script is the shared implementation. Board-specific workspaces should call it
    through thin wrappers that provide the board/workspace parameters.
.PARAMETER BoardId
    Mission Control board UUID.
.PARAMETER LeadWorkspacePath
    Absolute path to the lead workspace for this board.
.PARAMETER TaskId
    Task UUID to hand off.
.PARAMETER WorkerAgentId
    Worker agent UUID to assign.
.PARAMETER WorkerWorkspacePath
    Optional absolute worker workspace path. If omitted, derived as workspace-mc-<WorkerAgentId>
    next to the lead workspace.
.PARAMETER LeadAgentId
    Optional lead agent id for the sessions_spawn orchestration call. Defaults to lead-<BoardId>.
.PARAMETER BaseUrl
    Optional Mission Control API base URL. Defaults to BASE_URL from lead TOOLS.md.
.PARAMETER OutputDir
    Optional output directory for the bootstrap bundle. Defaults to <LeadWorkspacePath>/deliverables.
.PARAMETER DiagnosticsDir
    Optional diagnostics directory. Defaults to <LeadWorkspacePath>/diagnostics.
.PARAMETER BundleOnly
    Build and write the bootstrap bundle only, without spawn or task mutation.
#.PARAMETER DryRun
#    Do not call openclaw or PATCH the board. Instead, write the exact would-be actions to diagnostics.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BoardId,
    [Parameter(Mandatory = $true)][string]$LeadWorkspacePath,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$WorkerAgentId,
    [Parameter(Mandatory = $false)][string]$WorkerWorkspacePath,
    [Parameter(Mandatory = $false)][string]$LeadAgentId,
    [Parameter(Mandatory = $false)][string]$BaseUrl,
    [Parameter(Mandatory = $false)][string]$OutputDir,
    [Parameter(Mandatory = $false)][string]$DiagnosticsDir,
    [switch]$BundleOnly,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MdScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $pattern = "(?m)^\s*$([regex]::Escape($Key))\s*=\s*(.+?)\s*$"
    $match = [regex]::Match($content, $pattern)
    if (-not $match.Success) {
        throw "Missing '$Key' in $Path"
    }
    return $match.Groups[1].Value.Trim().Trim('`', '"', "'")
}

function Get-IdentityValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required identity file not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $pattern = "(?m)^\s*-\s*$([regex]::Escape($Key)):\s*(.+?)\s*$"
    $match = [regex]::Match($content, $pattern)
    if (-not $match.Success) {
        throw "Missing '$Key' in $Path"
    }
    return $match.Groups[1].Value.Trim()
}

function Read-WorkspaceFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    }
    catch {
        throw "Failed to read workspace file $Path : $($_.Exception.Message)"
    }
}

function ConvertTo-KebabCase {
    param([Parameter(Mandatory = $true)][string]$Text)

    $slug = $Text.ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    $slug = $slug.Trim('-')
    return $slug
}

function Try-ParseJson {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    try {
        return ($Text | ConvertFrom-Json -Depth 100)
    }
    catch {
        return $null
    }
}

function Resolve-SpawnResult {
    param([Parameter(Mandatory = $true)][string]$RawText)

    $parsed = Try-ParseJson -Text $RawText
    if ($parsed) {
        if ($parsed.PSObject.Properties.Name -contains 'childSessionKey') {
            return $parsed
        }
        if (($parsed.PSObject.Properties.Name -contains 'details') -and $parsed.details -and ($parsed.details.PSObject.Properties.Name -contains 'childSessionKey')) {
            return $parsed.details
        }
        if (($parsed.PSObject.Properties.Name -contains 'result') -and $parsed.result -and ($parsed.result.PSObject.Properties.Name -contains 'payloads')) {
            foreach ($payload in @($parsed.result.payloads)) {
                if ($payload -and ($payload.PSObject.Properties.Name -contains 'text')) {
                    $nested = Try-ParseJson -Text $payload.text
                    if ($nested -and ($nested.PSObject.Properties.Name -contains 'childSessionKey')) {
                        return $nested
                    }
                }
            }
        }
    }

    $sessionMatch = [regex]::Match($RawText, 'agent:[^\s"`]+:subagent:[0-9a-fA-F-]{36}')
    if ($sessionMatch.Success) {
        $runIdMatch = [regex]::Match($RawText, '"runId"\s*:\s*"([^"]+)"')
        return [pscustomobject]@{
            status = 'accepted'
            childSessionKey = $sessionMatch.Value
            runId = if ($runIdMatch.Success) { $runIdMatch.Groups[1].Value } else { $null }
            mode = 'run'
        }
    }

    throw "Could not resolve childSessionKey from spawn output."
}

function Write-FailureAndExit {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Message,
        [hashtable]$Context
    )

    $payload = [ordered]@{
        ok = $false
        phase = $Phase
        error = $Message
    }
    if ($Context) {
        foreach ($entry in $Context.GetEnumerator()) {
            $payload[$entry.Key] = $entry.Value
        }
    }
    $payload | ConvertTo-Json -Depth 12
    exit 1
}

function Invoke-BoardGet {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Token
    )

    return Invoke-RestMethod -Method Get -Uri $Uri -Headers @{ 'X-Agent-Token' = $Token } -TimeoutSec 20
}

function Invoke-BoardPatch {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Body,
        [Parameter(Mandatory = $true)][string]$Token
    )

    return Invoke-RestMethod -Method Patch -Uri $Uri -Headers @{ 'X-Agent-Token' = $Token } -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 12) -TimeoutSec 20
}

function Get-TaskProjection {
    param([Parameter(Mandatory = $true)][object]$TaskData)

    $preferredKeys = @(
        'id',
        'title',
        'description',
        'status',
        'priority',
        'due_at',
        'assigned_agent_id',
        'assignee',
        'closure_mode',
        'required_artifact_kinds',
        'required_check_kinds',
        'lead_spot_check_required',
        'depends_on_task_ids',
        'blocked_by_task_ids',
        'is_blocked',
        'tags',
        'tag_ids',
        'custom_field_values',
        'created_at',
        'updated_at'
    )

    $taskProjection = [ordered]@{}
    foreach ($key in $preferredKeys) {
        if ($TaskData.PSObject.Properties.Name -contains $key) {
            $taskProjection[$key] = $TaskData.$key
        }
    }
    return $taskProjection
}

function Get-TaskBundlePaths {
    param(
        [Parameter(Mandatory = $true)][string]$LeadWorkspacePath,
        [Parameter(Mandatory = $true)][string]$TaskId
    )

    $taskBundleDir = Join-Path $LeadWorkspacePath "tasks/$TaskId"
    $deliverablesDir = Join-Path $taskBundleDir 'deliverables'
    $evidenceDir = Join-Path $taskBundleDir 'evidence'

    Ensure-Directory -Path $taskBundleDir | Out-Null
    Ensure-Directory -Path $deliverablesDir | Out-Null
    Ensure-Directory -Path $evidenceDir | Out-Null

    return [ordered]@{
        task_directory = $taskBundleDir
        deliverables_directory = $deliverablesDir
        evidence_directory = $evidenceDir
    }
}

function Get-CommentsProjection {
    param($Comments = $null)

    $items = @()
    foreach ($comment in @($Comments | Where-Object { $null -ne $_ })) {
        $items += [ordered]@{
            id = $comment.id
            created_at = $comment.created_at
            author_name = $comment.author_name
            agent_id = $comment.agent_id
            agent_name = $comment.agent_name
            message = $comment.message
        }
    }
    return $items
}

function Get-ProjectKnowledge {
    param(
        [Parameter(Mandatory = $true)][string]$LeadWorkspacePath,
        [Parameter(Mandatory = $true)][object]$TaskData
    )

    $entries = @()
    $taskTags = @()
    if ($TaskData.PSObject.Properties.Name -contains 'tags') {
        $taskTags = @($TaskData.tags | Where-Object { $null -ne $_ })
    }

    foreach ($tag in $taskTags) {
        $tagName = $null
        if ($tag -is [string]) {
            $tagName = $tag
        } elseif ($tag.PSObject.Properties.Name -contains 'name') {
            $tagName = [string]$tag.name
        }

        if ([string]::IsNullOrWhiteSpace($tagName)) {
            continue
        }

        $slug = ConvertTo-KebabCase -Text $tagName
        $ledgerPath = Join-Path $LeadWorkspacePath "deliverables/ledger-$slug.json"
        if (-not (Test-Path -LiteralPath $ledgerPath)) {
            continue
        }

        $ledger = Try-ParseJson -Text (Read-WorkspaceFile -Path $ledgerPath)
        if (-not $ledger) {
            continue
        }

        $entries += [ordered]@{
            type = 'project_ledger'
            tag = $tagName
            slug = $slug
            path = $ledgerPath
            summary = [ordered]@{
                objective = $ledger.objective
                phase = $ledger.phase
                active_krs = @($ledger.active_krs)
                open_blockers = @($ledger.open_blockers)
                active_task_ids = @($ledger.active_task_ids)
                next_recommended_task_or_decision = $ledger.next_recommended_task_or_decision
                last_synced_at = $ledger.last_synced_at
            }
        }
    }

    return $entries
}

function New-BootstrapBundle {
    param(
        [Parameter(Mandatory = $true)][string]$BoardId,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$WorkerAgentId,
        [Parameter(Mandatory = $true)][string]$WorkerName,
        [Parameter(Mandatory = $true)][string]$LeadWorkspacePath,
        [Parameter(Mandatory = $true)][string]$WorkerWorkspacePath,
        [Parameter(Mandatory = $true)][object]$TaskData,
        $Comments = $null
    )

    $normalizedComments = @()
    if ($null -ne $Comments) {
        $normalizedComments = @($Comments | Where-Object { $null -ne $_ })
    }

    $taskBundlePaths = Get-TaskBundlePaths -LeadWorkspacePath $LeadWorkspacePath -TaskId $TaskId
    $verificationArtifactPath = $null
    if ($TaskData.title -match 'plan|planning|document|documentation|note|strategy|report|analysis') {
        $verificationArtifactPath = Join-Path $taskBundlePaths.deliverables_directory "evaluate-$TaskId.json"
    } else {
        $verificationArtifactPath = Join-Path $taskBundlePaths.deliverables_directory "verify-$TaskId.ps1"
    }

    return [ordered]@{
        metadata = [ordered]@{
            task_id = $TaskId
            board_id = $BoardId
            worker_agent_id = $WorkerAgentId
            worker_name = $WorkerName
            generated_at = [DateTime]::UtcNow.ToString('o')
            bundle_version = '3.0.0'
            bootstrap_mode = 'task_and_project_context_only'
        }
        worker_target = [ordered]@{
            workspace_path = $WorkerWorkspacePath
        }
        task_context = [ordered]@{
            task = Get-TaskProjection -TaskData $TaskData
            task_bundle_paths = $taskBundlePaths
            comments = Get-CommentsProjection -Comments $normalizedComments
        }
        retrieved_knowledge = @(Get-ProjectKnowledge -LeadWorkspacePath $LeadWorkspacePath -TaskData $TaskData)
        lead_handoff = [ordered]@{
            exact_output_contract = [ordered]@{
                task_bundle_directory = $taskBundlePaths.task_directory
                deliverables_directory = $taskBundlePaths.deliverables_directory
                evidence_directory = $taskBundlePaths.evidence_directory
                required_verification_artifact_path = $verificationArtifactPath
            }
            immediate_execution_instructions = @(
                'Do not duplicate or restate your workspace bootstrap files; they are already injected by OpenClaw.',
                'Treat the lead assignment patch as the canonical claim step.',
                'Treat any task status inside the bootstrap bundle as advisory context only; the live board state and lead assignment patch are authoritative.',
                'After the assignment patch becomes visible, post one concise task comment acknowledging the task and your short plan.',
                'Execute the task.',
                "Produce the requested primary deliverable inside: $($taskBundlePaths.deliverables_directory)",
                'Also produce a separate verification artifact: for deterministic work, a runnable verification script; for documentation or planning work, an evaluation spec for an LLM runner.',
                "Write the verification artifact to this exact path unless the task clearly requires a different extension: $verificationArtifactPath",
                'Prefer PowerShell for verification scripts unless the task clearly requires another runtime.',
                'Keep the main deliverable pure; do not embed self-test prose or attestation inside it.',
                'Do not write task outputs to the lead workspace root deliverables directory or your own workspace deliverables directory.',
                'When complete, post a handoff comment naming both deliverable paths explicitly and then move the task to review.',
                'If blocked, comment with the exact blocker and stop.'
            )
            notes = ''
        }
    }
}

function Get-OpenClawRoot {
    param([Parameter(Mandatory = $true)][string]$LeadWorkspacePath)
    return Split-Path -Parent $LeadWorkspacePath
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function New-DiagnosticsPath {
    param(
        [Parameter(Mandatory = $true)][string]$DiagnosticsDir,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    return Join-Path $DiagnosticsDir "$TaskId-$stamp-$Suffix.json"
}

function Write-DiagnosticsJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Data
    )

    $Data | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

$resolvedLeadWorkspace = (Resolve-Path -LiteralPath $LeadWorkspacePath).Path
$toolsPath = Join-Path $resolvedLeadWorkspace 'TOOLS.md'
$authToken = Get-MdScalar -Path $toolsPath -Key 'AUTH_TOKEN'

if (-not $BaseUrl) {
    $BaseUrl = Get-MdScalar -Path $toolsPath -Key 'BASE_URL'
}

if (-not $LeadAgentId) {
    $LeadAgentId = "lead-$BoardId"
}

if (-not $WorkerWorkspacePath) {
    $WorkerWorkspacePath = Join-Path (Get-OpenClawRoot -LeadWorkspacePath $resolvedLeadWorkspace) "workspace-mc-$WorkerAgentId"
}
$resolvedWorkerWorkspace = (Resolve-Path -LiteralPath $WorkerWorkspacePath).Path

if (-not $OutputDir) {
    $OutputDir = Join-Path $resolvedLeadWorkspace 'deliverables'
}
$resolvedOutputDir = Ensure-Directory -Path $OutputDir
$bundlePath = Join-Path $resolvedOutputDir "$TaskId-bootstrap.json"

if (-not $DiagnosticsDir) {
    $DiagnosticsDir = Join-Path $resolvedLeadWorkspace 'diagnostics'
}
$resolvedDiagnosticsDir = Ensure-Directory -Path $DiagnosticsDir

$workerName = Get-IdentityValue -Path (Join-Path $resolvedWorkerWorkspace 'IDENTITY.md') -Key 'Name'
$workerCanonicalId = $workerName.ToLowerInvariant()
$taskUri = "$BaseUrl/api/v1/agent/boards/$BoardId/tasks/$TaskId"
$commentsUri = "$taskUri/comments"

try {
    $task = Invoke-BoardGet -Uri $taskUri -Token $authToken
    $commentsResponse = Invoke-BoardGet -Uri $commentsUri -Token $authToken
}
catch {
    Write-FailureAndExit -Phase 'task_fetch' -Message $_.Exception.Message -Context @{
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        boardId = $BoardId
    }
}

$comments = @()
if ($commentsResponse) {
    if ($commentsResponse.PSObject.Properties.Name -contains 'items') {
        $comments = @($commentsResponse.items | Where-Object { $null -ne $_ })
    } elseif ($commentsResponse.PSObject.Properties.Name -contains 'comments') {
        $comments = @($commentsResponse.comments | Where-Object { $null -ne $_ })
    }
}

$bundleParams = @{
    BoardId = $BoardId
    TaskId = $TaskId
    WorkerAgentId = $WorkerAgentId
    WorkerName = $workerName
    LeadWorkspacePath = $resolvedLeadWorkspace
    WorkerWorkspacePath = $resolvedWorkerWorkspace
    TaskData = $task
}
if ($comments.Count -gt 0) {
    $bundleParams.Comments = $comments
}
$bundle = New-BootstrapBundle @bundleParams
$bundle | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bundlePath -Encoding UTF8

$taskBundlePaths = $bundle.task_context.task_bundle_paths
$requiredVerificationArtifactPath = $bundle.lead_handoff.exact_output_contract.required_verification_artifact_path

if ($BundleOnly) {
    [ordered]@{
        ok = $true
        mode = 'bundle_only'
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        workerCanonicalId = $workerCanonicalId
        bundlePath = $bundlePath
        task = Get-TaskProjection -TaskData $task
    } | ConvertTo-Json -Depth 12
    exit 0
}

$backlog = $false
if ($task.PSObject.Properties.Name -contains 'custom_field_values' -and $task.custom_field_values) {
    if ($task.custom_field_values.PSObject.Properties.Name -contains 'backlog') {
        $backlog = [bool]$task.custom_field_values.backlog
    }
}
if ($backlog) {
    Write-FailureAndExit -Phase 'precondition' -Message 'Task is backlog=true and is not assignable.' -Context @{
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        task = Get-TaskProjection -TaskData $task
    }
}

$workerTask = @"
You are $workerName. This board task has been handed to you through the lead orchestration workflow.

Task ID: $TaskId
Task Title: $($task.title)
Bootstrap Bundle: $bundlePath

Required behavior:
- Read the bootstrap bundle from disk before acting.
- Treat the lead's board patch as the canonical claim step.
- Treat any task status shown in the bootstrap bundle as advisory context only; if the lead assignment patch is visible, proceed even if bundled task status still says `inbox`.
- After the assignment patch becomes visible, post one concise task comment acknowledging the task and your short plan.
- Then execute the task.
- Use this exact task bundle directory: $($taskBundlePaths.task_directory)
- Write the main deliverable inside: $($taskBundlePaths.deliverables_directory)
- Also produce a separate verification artifact:
  - deterministic task: a runnable verification script, preferably in PowerShell
  - documentation/planning task: an evaluation spec for an LLM runner with structured pass/fail output
- Write the verification artifact to this exact path: $requiredVerificationArtifactPath
- Keep the main deliverable pure; do not embed self-test prose, validation notes, or attestation inside it.
- Do not write outputs to the lead workspace root deliverables directory.
- Do not write outputs to your own workspace deliverables directory.
- When complete, post a handoff comment naming both deliverable paths explicitly and move the task to review.
- If blocked, comment with the exact blocker and stop.
"@

$spawnPrompt = @"
Use sessions_spawn exactly once for this worker handoff.

Spawn parameters:
- agentId: $workerCanonicalId
- label: task:$TaskId
- runtime: subagent
- mode: run
- task: the worker instructions below

Worker instructions:
<<<TASK
$workerTask
TASK

After the tool call, reply with ONLY one JSON object and no markdown or prose:
{"status":"accepted|error","childSessionKey":"...","runId":"...","mode":"...","error":null}

If the tool result contains an error, copy it into the JSON object and set childSessionKey to null.
"@

if ($DryRun) {
    $predictedAssignmentPatch = [ordered]@{
        assigned_agent_id = $WorkerAgentId
        custom_field_values = @{
            subagent_uuid = '<subagent_uuid from sessions_spawn childSessionKey>'
        }
    }
    $predictedStatusPatch = [ordered]@{
        status = 'in_progress'
    }
    $dryRunRecord = [ordered]@{
        ok = $true
        mode = 'dry_run'
        taskId = $TaskId
        boardId = $BoardId
        workerAgentId = $WorkerAgentId
        workerCanonicalId = $workerCanonicalId
        bundlePath = $bundlePath
        diagnosticsDir = $resolvedDiagnosticsDir
        task = Get-TaskProjection -TaskData $task
        actions = @(
            [ordered]@{
                step = 'subagent_spawn'
                type = 'openclaw_agent'
                program = 'openclaw'
                arguments = @(
                    'agent',
                    '--agent', $LeadAgentId,
                    '--message', $spawnPrompt,
                    '--json',
                    '--timeout', '120',
                    '--thinking', 'off'
                )
                targetAgent = $LeadAgentId
                message = $spawnPrompt
            },
            [ordered]@{
                step = 'patch_assignment'
                type = 'board_patch'
                method = 'PATCH'
                uri = $taskUri
                body = $predictedAssignmentPatch
            },
            [ordered]@{
                step = 'patch_status'
                type = 'board_patch'
                method = 'PATCH'
                uri = $taskUri
                body = $predictedStatusPatch
            },
            [ordered]@{
                step = 'verify_final_task'
                type = 'board_get'
                method = 'GET'
                uri = $taskUri
            }
        )
    }
    $dryRunPath = New-DiagnosticsPath -DiagnosticsDir $resolvedDiagnosticsDir -TaskId $TaskId -Suffix 'mc-assign-dryrun'
    Write-DiagnosticsJson -Path $dryRunPath -Data $dryRunRecord | Out-Null
    $dryRunRecord['dryRunTracePath'] = $dryRunPath
    $dryRunRecord | ConvertTo-Json -Depth 16
    exit 0
}

$spawnRaw = & openclaw agent --agent $LeadAgentId --message $spawnPrompt --json --timeout 120 --thinking off 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-FailureAndExit -Phase 'subagent_spawn' -Message "Lead handoff spawn command failed (exit $LASTEXITCODE)" -Context @{
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        workerCanonicalId = $workerCanonicalId
        bundlePath = $bundlePath
        spawnOutput = ($spawnRaw -join "`n")
    }
}

try {
    $spawnResult = Resolve-SpawnResult -RawText ($spawnRaw -join "`n")
}
catch {
    Write-FailureAndExit -Phase 'subagent_spawn' -Message $_.Exception.Message -Context @{
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        workerCanonicalId = $workerCanonicalId
        bundlePath = $bundlePath
        spawnOutput = ($spawnRaw -join "`n")
    }
}

$childSessionKey = $spawnResult.childSessionKey
if ([string]::IsNullOrWhiteSpace($childSessionKey)) {
    Write-FailureAndExit -Phase 'subagent_spawn' -Message 'Spawn response did not include childSessionKey.' -Context @{
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        workerCanonicalId = $workerCanonicalId
        bundlePath = $bundlePath
        spawn = $spawnResult
    }
}

$uuidMatch = [regex]::Match($childSessionKey, ':subagent:([0-9a-fA-F-]{36})$')
if (-not $uuidMatch.Success) {
    Write-FailureAndExit -Phase 'subagent_spawn' -Message 'Could not derive subagent UUID from childSessionKey.' -Context @{
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        workerCanonicalId = $workerCanonicalId
        bundlePath = $bundlePath
        childSessionKey = $childSessionKey
    }
}
$subagentUuid = $uuidMatch.Groups[1].Value

# Ensure assigned_agent_id uses bare UUID (strip 'mc-' prefix if present)
$assignedAgentId = $WorkerAgentId
if ($assignedAgentId -like 'mc-*') {
    $assignedAgentId = $assignedAgentId.Substring(3)
}

try {
    $combinedPatch = Invoke-BoardPatch -Uri $taskUri -Token $authToken -Body @{
        assigned_agent_id = $assignedAgentId
        status = 'in_progress'
        custom_field_values = @{
            subagent_uuid = $subagentUuid
        }
    }
    $assignmentPatch = $combinedPatch
    $statusPatch = $combinedPatch
}
catch {
    Write-FailureAndExit -Phase 'patch_assignment_status' -Message $_.Exception.Message -Context @{
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        workerCanonicalId = $workerCanonicalId
        bundlePath = $bundlePath
        childSessionKey = $childSessionKey
        subagent_uuid = $subagentUuid
    }
}

try {
    $finalTask = Invoke-BoardGet -Uri $taskUri -Token $authToken
}
catch {
    Write-FailureAndExit -Phase 'task_fetch_final' -Message $_.Exception.Message -Context @{
        taskId = $TaskId
        workerAgentId = $WorkerAgentId
        workerCanonicalId = $workerCanonicalId
        bundlePath = $bundlePath
        childSessionKey = $childSessionKey
        subagent_uuid = $subagentUuid
        assignmentPatch = $assignmentPatch
        statusPatch = $statusPatch
    }
}

[ordered]@{
    ok = $true
    mode = 'assign'
    taskId = $TaskId
    boardId = $BoardId
    workerAgentId = $WorkerAgentId
    workerCanonicalId = $workerCanonicalId
    bundlePath = $bundlePath
    spawn = [ordered]@{
        status = $spawnResult.status
        childSessionKey = $childSessionKey
        runId = $spawnResult.runId
        mode = $spawnResult.mode
        subagent_uuid = $subagentUuid
    }
    patches = [ordered]@{
        assignment = $assignmentPatch
        status = $statusPatch
    }
    finalTask = Get-TaskProjection -TaskData $finalTask
} | ConvertTo-Json -Depth 12
