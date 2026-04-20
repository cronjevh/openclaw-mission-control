function Get-MconMdScalar {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
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

function Get-MconIdentityValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
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

function Get-MconWorkspaceFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    } catch {
        throw "Failed to read workspace file $Path : $($_.Exception.Message)"
    }
}

function ConvertFrom-MconKebabCase {
    param([Parameter(Mandatory)][string]$Text)

    $slug = $Text.ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    return $slug.Trim('-')
}

function ConvertFrom-MconJsonSafe {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        return ($Text | ConvertFrom-Json -Depth 100)
    } catch {
        return $null
    }
}

function Resolve-MconSpawnResult {
    param([Parameter(Mandatory)][string]$RawText)

    $parsed = ConvertFrom-MconJsonSafe -Text $RawText
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
                    $nested = ConvertFrom-MconJsonSafe -Text $payload.text
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
            status           = 'accepted'
            childSessionKey  = $sessionMatch.Value
            runId            = if ($runIdMatch.Success) { $runIdMatch.Groups[1].Value } else { $null }
            mode             = 'run'
        }
    }

    throw "Could not resolve childSessionKey from spawn output."
}

function New-MconDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Write-MconWorkerTaskData {
    param(
        [Parameter(Mandatory)][string]$WorkerWorkspacePath,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$LeadAgentId,
        [Parameter(Mandatory)][string]$InvocationAgentId,
        [Parameter(Mandatory)][object]$TaskData,
        [Parameter(Mandatory)]$Comments,
        [Parameter(Mandatory)]$TaskBundlePaths
    )

    $taskId = [string]$TaskData.id
    $taskDir = Join-Path $WorkerWorkspacePath "tasks/$taskId"
    $deliverablesDir = Join-Path $taskDir 'deliverables'
    $evidenceDir = Join-Path $taskDir 'evidence'

    foreach ($dir in @($taskDir, $deliverablesDir, $evidenceDir)) {
        New-MconDirectory -Path $dir | Out-Null
    }

    $normalizedComments = Get-MconAssignCommentsProjection -Comments $Comments
    $taskDataPath = Join-Path $taskDir 'taskData.json'
    $workerTaskData = [ordered]@{
        generated_at           = (Get-Date).ToUniversalTime().ToString('o')
        board_id               = $BoardId
        lead_agent_id          = $LeadAgentId
        invocation_agent_id    = $InvocationAgentId
        task_directory         = $TaskBundlePaths.task_directory
        deliverables_directory = $TaskBundlePaths.deliverables_directory
        evidence_directory     = $TaskBundlePaths.evidence_directory
        task_context           = [ordered]@{
            task              = Get-MconAssignTaskProjection -TaskData $TaskData
            task_bundle_paths = $TaskBundlePaths
            comments          = $normalizedComments
        }
        task     = $TaskData
        comments = $normalizedComments
    }

    $workerTaskData | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $taskDataPath -Encoding UTF8
    return $taskDataPath
}

function Get-MconAssignTaskProjection {
    param([Parameter(Mandatory)][object]$TaskData)

    $preferredKeys = @(
        'id', 'title', 'description', 'status', 'priority', 'due_at',
        'assigned_agent_id', 'assignee', 'closure_mode',
        'required_artifact_kinds', 'required_check_kinds', 'lead_spot_check_required',
        'depends_on_task_ids', 'blocked_by_task_ids', 'is_blocked',
        'tags', 'tag_ids', 'custom_field_values', 'created_at', 'updated_at'
    )

    $taskProjection = [ordered]@{}
    foreach ($key in $preferredKeys) {
        if ($TaskData.PSObject.Properties.Name -contains $key) {
            $taskProjection[$key] = $TaskData.$key
        }
    }
    return $taskProjection
}

function Get-MconAssignTaskBundlePaths {
    param(
        [Parameter(Mandatory)][string]$LeadWorkspacePath,
        [Parameter(Mandatory)][string]$TaskId
    )

    $taskBundleDir = Join-Path $LeadWorkspacePath "tasks/$TaskId"
    $deliverablesDir = Join-Path $taskBundleDir 'deliverables'
    $evidenceDir = Join-Path $taskBundleDir 'evidence'

    New-MconDirectory -Path $taskBundleDir | Out-Null
    New-MconDirectory -Path $deliverablesDir | Out-Null
    New-MconDirectory -Path $evidenceDir | Out-Null

    return [ordered]@{
        task_directory         = $taskBundleDir
        deliverables_directory = $deliverablesDir
        evidence_directory     = $evidenceDir
    }
}

function Get-MconAssignCommentsProjection {
    param($Comments = $null)

    $items = @()
    foreach ($comment in @($Comments | Where-Object { $null -ne $_ })) {
        $items += [ordered]@{
            id          = $comment.id
            created_at  = $comment.created_at
            author_name = $comment.author_name
            agent_id    = $comment.agent_id
            agent_name  = $comment.agent_name
            message     = $comment.message
        }
    }
    return $items
}

function Get-MconProjectKnowledge {
    param(
        [Parameter(Mandatory)][string]$LeadWorkspacePath,
        [Parameter(Mandatory)][object]$TaskData
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

        if ([string]::IsNullOrWhiteSpace($tagName)) { continue }

        $slug = ConvertFrom-MconKebabCase -Text $tagName
        $ledgerPath = Join-Path $LeadWorkspacePath "deliverables/ledger-$slug.json"
        if (-not (Test-Path -LiteralPath $ledgerPath)) { continue }

        $ledger = ConvertFrom-MconJsonSafe -Text (Get-MconWorkspaceFile -Path $ledgerPath)
        if (-not $ledger) { continue }

        $entries += [ordered]@{
            type = 'project_ledger'
            tag  = $tagName
            slug = $slug
            path = $ledgerPath
            summary = [ordered]@{
                objective                         = $ledger.objective
                phase                             = $ledger.phase
                active_krs                        = @($ledger.active_krs)
                open_blockers                     = @($ledger.open_blockers)
                active_task_ids                   = @($ledger.active_task_ids)
                next_recommended_task_or_decision = $ledger.next_recommended_task_or_decision
                last_synced_at                    = $ledger.last_synced_at
            }
        }
    }

    return $entries
}

function New-MconBootstrapBundle {
    param(
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$WorkerAgentId,
        [Parameter(Mandatory)][string]$WorkerName,
        [Parameter(Mandatory)][string]$LeadWorkspacePath,
        [Parameter(Mandatory)][string]$WorkerWorkspacePath,
        [Parameter(Mandatory)][object]$TaskData,
        $Comments = $null
    )

    $normalizedComments = @()
    if ($null -ne $Comments) {
        $normalizedComments = @($Comments | Where-Object { $null -ne $_ })
    }

    $taskBundlePaths = Get-MconAssignTaskBundlePaths -LeadWorkspacePath $LeadWorkspacePath -TaskId $TaskId
    $verificationArtifactPath = $null
    if ($TaskData.title -match 'plan|planning|document|documentation|note|strategy|report|analysis') {
        $verificationArtifactPath = Join-Path $taskBundlePaths.deliverables_directory "evaluate-$TaskId.json"
    } else {
        $verificationArtifactPath = Join-Path $taskBundlePaths.deliverables_directory "verify-$TaskId.ps1"
    }

    return [ordered]@{
        metadata = [ordered]@{
            task_id         = $TaskId
            board_id        = $BoardId
            worker_agent_id = $WorkerAgentId
            worker_name     = $WorkerName
            generated_at    = [DateTime]::UtcNow.ToString('o')
            bundle_version  = '3.0.0'
            bootstrap_mode  = 'task_and_project_context_only'
        }
        worker_target = [ordered]@{
            workspace_path = $WorkerWorkspacePath
        }
        task_context = [ordered]@{
            task              = Get-MconAssignTaskProjection -TaskData $TaskData
            task_bundle_paths = $taskBundlePaths
            comments          = Get-MconAssignCommentsProjection -Comments $normalizedComments
        }
        retrieved_knowledge = @(Get-MconProjectKnowledge -LeadWorkspacePath $LeadWorkspacePath -TaskData $TaskData)
        lead_handoff = [ordered]@{
            exact_output_contract = [ordered]@{
                task_bundle_directory             = $taskBundlePaths.task_directory
                deliverables_directory             = $taskBundlePaths.deliverables_directory
                evidence_directory                 = $taskBundlePaths.evidence_directory
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

function New-MconDiagnosticsPath {
    param(
        [Parameter(Mandatory)][string]$DiagnosticsDir,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Suffix
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    return Join-Path $DiagnosticsDir "$TaskId-$stamp-$Suffix.json"
}

function Write-MconDiagnosticsJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Data
    )

    $Data | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function Invoke-MconAssign {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$WorkerAgentId,
        [string]$WorkerWorkspacePath,
        [string]$LeadAgentId,
        [string]$OutputDir,
        [string]$DiagnosticsDir,
        [switch]$BundleOnly,
        [switch]$DryRun
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id
    $agentId = $Config.agent_id
    $workspacePath = $Config.workspace_path

    if (-not $LeadAgentId) {
        $LeadAgentId = "lead-$boardId"
    }

    $encodedBoardId = [uri]::EscapeDataString($boardId)
    $encodedTaskId = [uri]::EscapeDataString($TaskId)
    $taskUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/tasks/$encodedTaskId"
    $commentsUri = "$taskUri/comments"

    try {
        $task = Invoke-MconApi -Method Get -Uri $taskUri -Token $authToken
        $commentsResponse = Invoke-MconApi -Method Get -Uri $commentsUri -Token $authToken
    } catch {
        return [ordered]@{
            ok     = $false
            phase  = 'task_fetch'
            error  = $_.Exception.Message
            taskId = $TaskId
            workerAgentId = $WorkerAgentId
            boardId = $boardId
        }
    }

    $isBlocked = $false
    $blockedByTaskIds = @()
    if ($task.PSObject.Properties.Name -contains 'is_blocked' -and $task.is_blocked) {
        $isBlocked = $true
    }
    if ($task.PSObject.Properties.Name -contains 'blocked_by_task_ids' -and $task.blocked_by_task_ids) {
        $blockedByTaskIds = @($task.blocked_by_task_ids | Where-Object { $_ })
    }
    if ($isBlocked -or $blockedByTaskIds.Count -gt 0) {
        $depList = ($blockedByTaskIds -join ', ')
        return [ordered]@{
            ok            = $false
            phase         = 'precondition'
            error         = "Task has unmet dependencies and is blocked. Blocked by task(s): $depList. Resolve dependencies before assigning."
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            task          = Get-MconAssignTaskProjection -TaskData $task
        }
    }

    if (-not $WorkerWorkspacePath) {
        $openClawRoot = Split-Path -Parent $workspacePath
        $WorkerWorkspacePath = Join-Path $openClawRoot "workspace-mc-$WorkerAgentId"
    }
    if (-not (Test-Path -LiteralPath $WorkerWorkspacePath)) {
        throw "Worker workspace not found: $WorkerWorkspacePath"
    }
    $resolvedWorkerWorkspace = (Resolve-Path -LiteralPath $WorkerWorkspacePath).Path

    if (-not $OutputDir) {
        $OutputDir = Join-Path $workspacePath 'deliverables'
    }
    $resolvedOutputDir = New-MconDirectory -Path $OutputDir
    $bundlePath = Join-Path $resolvedOutputDir "$TaskId-bootstrap.json"

    if (-not $DiagnosticsDir) {
        $DiagnosticsDir = Join-Path $workspacePath 'diagnostics'
    }
    $resolvedDiagnosticsDir = New-MconDirectory -Path $DiagnosticsDir

    $workerName = Get-MconIdentityValue -Path (Join-Path $resolvedWorkerWorkspace 'IDENTITY.md') -Key 'Name'
    $workerLegacyAgentName = $workerName.ToLowerInvariant()
    $workerSpawnAgentId = if ($WorkerAgentId -like 'mc-*') { $WorkerAgentId } else { "mc-$WorkerAgentId" }

    $comments = @()
    if ($commentsResponse) {
        if ($commentsResponse.PSObject.Properties.Name -contains 'items') {
            $comments = @($commentsResponse.items | Where-Object { $null -ne $_ })
        } elseif ($commentsResponse.PSObject.Properties.Name -contains 'comments') {
            $comments = @($commentsResponse.comments | Where-Object { $null -ne $_ })
        }
    }

    $bundleParams = @{
        BoardId            = $boardId
        TaskId             = $TaskId
        WorkerAgentId      = $WorkerAgentId
        WorkerName         = $workerName
        LeadWorkspacePath  = $workspacePath
        WorkerWorkspacePath = $resolvedWorkerWorkspace
        TaskData           = $task
    }
    if ($comments.Count -gt 0) {
        $bundleParams.Comments = $comments
    }
    $bundle = New-MconBootstrapBundle @bundleParams
    $bundle | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bundlePath -Encoding UTF8

    $taskBundlePaths = $bundle.task_context.task_bundle_paths
    $requiredVerificationArtifactPath = $bundle.lead_handoff.exact_output_contract.required_verification_artifact_path
    $workerTaskDataPath = Write-MconWorkerTaskData `
        -WorkerWorkspacePath $resolvedWorkerWorkspace `
        -BoardId $boardId `
        -LeadAgentId $agentId `
        -InvocationAgentId $agentId `
        -TaskData $task `
        -Comments $comments `
        -TaskBundlePaths $taskBundlePaths

    if ($BundleOnly) {
        return [ordered]@{
            ok                = $true
            mode              = 'bundle_only'
            taskId            = $TaskId
            workerAgentId     = $WorkerAgentId
            workerSpawnAgentId = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath        = $bundlePath
            workerTaskDataPath = $workerTaskDataPath
            task              = Get-MconAssignTaskProjection -TaskData $task
        }
    }

    $backlog = $false
    if ($task.PSObject.Properties.Name -contains 'custom_field_values' -and $task.custom_field_values) {
        if ($task.custom_field_values.PSObject.Properties.Name -contains 'backlog') {
            $backlog = [bool]$task.custom_field_values.backlog
        }
    }
    if ($backlog) {
        return [ordered]@{
            ok            = $false
            phase         = 'precondition'
            error         = 'Task is backlog=true and is not assignable.'
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            task          = Get-MconAssignTaskProjection -TaskData $task
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
- agentId: $workerSpawnAgentId
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
            assigned_agent_id    = $WorkerAgentId
            custom_field_values  = @{ subagent_uuid = '<subagent_uuid from sessions_spawn childSessionKey>' }
        }
        $predictedStatusPatch = [ordered]@{
            status = 'in_progress'
        }
        $dryRunRecord = [ordered]@{
            ok                = $true
            mode              = 'dry_run'
            taskId            = $TaskId
            boardId           = $boardId
            workerAgentId     = $WorkerAgentId
            workerSpawnAgentId = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath        = $bundlePath
            workerTaskDataPath = $workerTaskDataPath
            diagnosticsDir    = $resolvedDiagnosticsDir
            task              = Get-MconAssignTaskProjection -TaskData $task
            actions           = @(
                [ordered]@{
                    step        = 'subagent_spawn'
                    type        = 'openclaw_agent'
                    program     = 'openclaw'
                    arguments   = @('agent', '--agent', $LeadAgentId, '--message', $spawnPrompt, '--json', '--timeout', '120', '--thinking', 'off')
                    targetAgent = $LeadAgentId
                    message     = $spawnPrompt
                },
                [ordered]@{
                    step   = 'patch_assignment'
                    type   = 'board_patch'
                    method = 'PATCH'
                    uri    = $taskUri
                    body   = $predictedAssignmentPatch
                },
                [ordered]@{
                    step   = 'patch_status'
                    type   = 'board_patch'
                    method = 'PATCH'
                    uri    = $taskUri
                    body   = $predictedStatusPatch
                },
                [ordered]@{
                    step   = 'verify_final_task'
                    type   = 'board_get'
                    method = 'GET'
                    uri    = $taskUri
                }
            )
        }
        $dryRunPath = New-MconDiagnosticsPath -DiagnosticsDir $resolvedDiagnosticsDir -TaskId $TaskId -Suffix 'mc-assign-dryrun'
        Write-MconDiagnosticsJson -Path $dryRunPath -Data $dryRunRecord | Out-Null
        $dryRunRecord['dryRunTracePath'] = $dryRunPath
        return $dryRunRecord
    }

    $spawnRaw = & openclaw agent --agent $LeadAgentId --message $spawnPrompt --json --timeout 120 --thinking off 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [ordered]@{
            ok            = $false
            phase         = 'subagent_spawn'
            error         = "Lead handoff spawn command failed (exit $LASTEXITCODE)"
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            workerSpawnAgentId = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath    = $bundlePath
            workerTaskDataPath = $workerTaskDataPath
            spawnOutput   = ($spawnRaw -join "`n")
        }
    }

    try {
        $spawnResult = Resolve-MconSpawnResult -RawText ($spawnRaw -join "`n")
    } catch {
        return [ordered]@{
            ok            = $false
            phase         = 'subagent_spawn'
            error         = $_.Exception.Message
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            workerSpawnAgentId = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath    = $bundlePath
            workerTaskDataPath = $workerTaskDataPath
            spawnOutput   = ($spawnRaw -join "`n")
        }
    }

    $childSessionKey = $spawnResult.childSessionKey
    if ([string]::IsNullOrWhiteSpace($childSessionKey)) {
        return [ordered]@{
            ok            = $false
            phase         = 'subagent_spawn'
            error         = 'Spawn response did not include childSessionKey.'
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            workerSpawnAgentId = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath    = $bundlePath
            workerTaskDataPath = $workerTaskDataPath
            spawn         = $spawnResult
        }
    }

    $uuidMatch = [regex]::Match($childSessionKey, ':subagent:([0-9a-fA-F-]{36})$')
    if (-not $uuidMatch.Success) {
        return [ordered]@{
            ok            = $false
            phase         = 'subagent_spawn'
            error         = 'Could not derive subagent UUID from childSessionKey.'
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            workerSpawnAgentId = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath    = $bundlePath
            workerTaskDataPath = $workerTaskDataPath
            childSessionKey = $childSessionKey
        }
    }
    $subagentUuid = $uuidMatch.Groups[1].Value

    $assignedAgentId = $WorkerAgentId
    if ($assignedAgentId -like 'mc-*') {
        $assignedAgentId = $assignedAgentId.Substring(3)
    }

    try {
        $combinedPatch = Invoke-MconApi -Method Patch -Uri $taskUri -Token $authToken -Body @{
            assigned_agent_id   = $assignedAgentId
            status              = 'in_progress'
            custom_field_values = @{ subagent_uuid = $subagentUuid }
        }
        $assignmentPatch = $combinedPatch
        $statusPatch = $combinedPatch
    } catch {
        return [ordered]@{
            ok            = $false
            phase         = 'patch_assignment_status'
            error         = $_.Exception.Message
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            workerSpawnAgentId = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath    = $bundlePath
            workerTaskDataPath = $workerTaskDataPath
            childSessionKey = $childSessionKey
            subagent_uuid = $subagentUuid
        }
    }

    try {
        $finalTask = Invoke-MconApi -Method Get -Uri $taskUri -Token $authToken
    } catch {
        return [ordered]@{
            ok            = $false
            phase         = 'task_fetch_final'
            error         = $_.Exception.Message
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            workerSpawnAgentId = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath    = $bundlePath
            workerTaskDataPath = $workerTaskDataPath
            childSessionKey = $childSessionKey
            subagent_uuid = $subagentUuid
            assignmentPatch = $assignmentPatch
            statusPatch   = $statusPatch
        }
    }

    return [ordered]@{
        ok                = $true
        mode              = 'assign'
        taskId            = $TaskId
        boardId           = $boardId
        workerAgentId     = $WorkerAgentId
        workerSpawnAgentId = $workerSpawnAgentId
        workerLegacyAgentName = $workerLegacyAgentName
        bundlePath        = $bundlePath
        workerTaskDataPath = $workerTaskDataPath
        spawn             = [ordered]@{
            status           = $spawnResult.status
            childSessionKey  = $childSessionKey
            runId            = $spawnResult.runId
            mode             = $spawnResult.mode
            subagent_uuid    = $subagentUuid
        }
        patches = [ordered]@{
            assignment = $assignmentPatch
            status     = $statusPatch
        }
        finalTask = Get-MconAssignTaskProjection -TaskData $finalTask
    }
}

Export-ModuleMember -Function Invoke-MconAssign
