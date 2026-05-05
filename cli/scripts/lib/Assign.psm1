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

function Resolve-MconGatewayChatResponseText {
    param([Parameter(Mandatory)]$Response)

    if ($null -eq $Response) {
        throw 'Gateway chat returned no response.'
    }

    if ($Response.PSObject.Properties.Name -contains 'choices') {
        $choices = @($Response.choices | Where-Object { $null -ne $_ })
        if ($choices.Count -gt 0) {
            $firstChoice = $choices[0]
            if (
                $firstChoice.PSObject.Properties.Name -contains 'message' -and
                $firstChoice.message -and
                $firstChoice.message.PSObject.Properties.Name -contains 'content' -and
                -not [string]::IsNullOrWhiteSpace([string]$firstChoice.message.content)
            ) {
                return [string]$firstChoice.message.content
            }
        }
    }

    throw 'Gateway chat response did not include assistant message content.'
}

function Get-MconNormalizedWorkerAgentId {
    param([string]$AgentId)

    if ([string]::IsNullOrWhiteSpace($AgentId)) {
        return $null
    }

    $normalized = [string]$AgentId
    if ($normalized -like 'mc-*') {
        return $normalized.Substring(3)
    }

    return $normalized
}

function Get-MconTaskSubagentUuid {
    param([Parameter(Mandatory)][object]$TaskData)

    if ($TaskData.PSObject.Properties.Name -contains 'custom_field_values' -and $TaskData.custom_field_values) {
        if ($TaskData.custom_field_values.PSObject.Properties.Name -contains 'subagent_uuid' -and $TaskData.custom_field_values.subagent_uuid) {
            return [string]$taskData.custom_field_values.subagent_uuid
        }
    } elseif ($TaskData.PSObject.Properties.Name -contains 'subagent_uuid' -and $TaskData.subagent_uuid) {
        return [string]$TaskData.subagent_uuid
    }

    return $null
}

function Get-MconAssignmentOriginSessionKey {
    param(
        [string]$OriginSessionKey
    )

    if ($OriginSessionKey -and $OriginSessionKey.Trim()) {
        return $OriginSessionKey.Trim()
    }

    foreach ($envName in @('MCON_ORIGIN_SESSION_KEY', 'OPENCLAW_SESSION_KEY')) {
        $value = [Environment]::GetEnvironmentVariable($envName)
        if ($value -and $value.Trim()) {
            return $value.Trim()
        }
    }

    return $null
}

function ConvertTo-MconCanonicalAssignmentSessionKey {
    param(
        [string]$OriginSessionKey
    )

    if ([string]::IsNullOrWhiteSpace($OriginSessionKey)) {
        return $null
    }

    $match = [regex]::Match(
        $OriginSessionKey.Trim(),
        '^(?:agent:[^:]+:)?(?<kind>task|tag):(?<itemId>[0-9a-fA-F-]{36})$'
    )
    if (-not $match.Success) {
        return $null
    }

    return "$($match.Groups['kind'].Value):$($match.Groups['itemId'].Value)"
}

function Resolve-MconAssignmentRuntimeSessionKey {
    param(
        [Parameter(Mandatory)][string]$LeadAgentId,
        [string]$OriginSessionKey
    )

    if ([string]::IsNullOrWhiteSpace($OriginSessionKey)) {
        return $null
    }

    $trimmed = $OriginSessionKey.Trim()
    if ($trimmed -match '^agent:[^:]+:(?:task|tag):[0-9a-fA-F-]{36}$') {
        return $trimmed
    }

    $canonical = ConvertTo-MconCanonicalAssignmentSessionKey -OriginSessionKey $trimmed
    if ([string]::IsNullOrWhiteSpace($canonical)) {
        return $null
    }

    return "agent:$($LeadAgentId):$canonical"
}

function Get-MconTaskTagIds {
    param(
        [Parameter(Mandatory)]$TaskData
    )

    $tagIds = @()
    if ($TaskData.PSObject.Properties.Name -contains 'tag_ids' -and $TaskData.tag_ids) {
        $tagIds += @($TaskData.tag_ids | Where-Object { $_ })
    }
    if ($TaskData.PSObject.Properties.Name -contains 'tags' -and $TaskData.tags) {
        foreach ($tag in @($TaskData.tags | Where-Object { $_ })) {
            if ($tag -is [string]) {
                continue
            }
            if ($tag.PSObject.Properties.Name -contains 'id' -and $tag.id) {
                $tagIds += [string]$tag.id
            }
        }
    }

    return @($tagIds | Select-Object -Unique)
}

function Assert-MconAssignmentOrigin {
    param(
        [string]$OriginSessionKey,
        $TaskData = $null
    )

    if ([string]::IsNullOrWhiteSpace($OriginSessionKey)) {
        throw "workflow.assign requires an origin session key. Pass --origin-session-key task:<uuid> or tag:<uuid>, or a heartbeat sessionKey like agent:<scope>:task:<uuid> / agent:<scope>:tag:<uuid>, or set MCON_ORIGIN_SESSION_KEY."
    }

    $rawOriginSessionKey = $OriginSessionKey
    $OriginSessionKey = ConvertTo-MconCanonicalAssignmentSessionKey -OriginSessionKey $OriginSessionKey
    if ([string]::IsNullOrWhiteSpace($OriginSessionKey)) {
        throw "workflow.assign requires an origin session key in one of these forms: task:<uuid>, tag:<uuid>, or a heartbeat sessionKey like agent:<scope>:task:<uuid> / agent:<scope>:tag:<uuid>; got '$rawOriginSessionKey'."
    }

    $taskKeyMatch = [regex]::Match($OriginSessionKey, '^task:(?<taskId>[0-9a-fA-F-]{36})$')
    if ($taskKeyMatch.Success) {
        if ($null -eq $TaskData) {
            return
        }
        $originTaskId = $taskKeyMatch.Groups['taskId'].Value
        if ($TaskData.id -ne $originTaskId) {
            throw "workflow.assign origin session key $OriginSessionKey does not match task $($TaskData.id)."
        }

        $isBacklog = $false
        if ($TaskData.PSObject.Properties.Name -contains 'backlog' -and $TaskData.backlog) {
            $isBacklog = [bool]$TaskData.backlog
        } elseif ($TaskData.PSObject.Properties.Name -contains 'custom_field_values') {
            $cf = $TaskData.custom_field_values
            if ($cf -and $cf.PSObject.Properties.Name -contains 'backlog' -and $cf.backlog) {
                $isBacklog = [bool]$cf.backlog
            }
        }

        if ($TaskData.PSObject.Properties.Name -contains 'status') {
            $status = [string]$TaskData.status
            if (($status -ne 'inbox') -and $isBacklog) {
                throw "workflow.assign origin task $OriginSessionKey is not assignable because task $($TaskData.id) is not inbox and backlog=true."
            }
        }

        return
    }

    $tagKeyMatch = [regex]::Match($OriginSessionKey, '^tag:(?<tagId>[0-9a-fA-F-]{36})$')
    if ($tagKeyMatch.Success) {
        if ($null -eq $TaskData) {
            return
        }
        $originTagId = $tagKeyMatch.Groups['tagId'].Value
        $taskTagIds = Get-MconTaskTagIds -TaskData $TaskData
        if (-not ($taskTagIds -contains $originTagId)) {
            throw "workflow.assign origin session key $OriginSessionKey does not match any tag on task $($TaskData.id)."
        }

        $isBacklog = $false
        if ($TaskData.PSObject.Properties.Name -contains 'backlog' -and $TaskData.backlog) {
            $isBacklog = [bool]$TaskData.backlog
        } elseif ($TaskData.PSObject.Properties.Name -contains 'custom_field_values') {
            $cf = $TaskData.custom_field_values
            if ($cf -and $cf.PSObject.Properties.Name -contains 'backlog' -and $cf.backlog) {
                $isBacklog = [bool]$cf.backlog
            }
        }

        if ($TaskData.PSObject.Properties.Name -contains 'status') {
            $status = [string]$TaskData.status
            if (($status -ne 'inbox') -and $isBacklog) {
                throw "workflow.assign origin tag $OriginSessionKey is not assignable because task $($TaskData.id) is not inbox and backlog=true."
            }
        }

        return
    }

    throw "workflow.assign requires an origin session key normalized to task:<uuid> or tag:<uuid>; got '$OriginSessionKey'."
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
        'tags', 'tag_ids', 'custom_field_values', 'created_at', 'updated_at',
        'task_class'
    )

    $taskProjection = [ordered]@{
    }
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
                'If blocked, run `mcon workflow blocker`  including the full detailed explanation in the message parameter for why you are blocked.'
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
        [string]$OriginSessionKey,
        [string]$WorkerWorkspacePath,
        [string]$LeadAgentId,
        [string]$OutputDir,
        [string]$DiagnosticsDir,
        [string]$MconScriptPath,
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

    $resolvedOriginSessionKey = Get-MconAssignmentOriginSessionKey -OriginSessionKey $OriginSessionKey
    try {
        Assert-MconAssignmentOrigin -OriginSessionKey $resolvedOriginSessionKey
    } catch {
        return [ordered]@{
            ok            = $false
            phase         = 'origin_validation'
            error         = $_.Exception.Message
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            originSessionKey = $resolvedOriginSessionKey
        }
    }

    $task = $null
    $dispatchStatePath = Get-MconDispatchStatePath -WorkspacePath $workspacePath
    if (Test-Path -LiteralPath $dispatchStatePath) {
        try {
            $dispatchState = Get-Content -LiteralPath $dispatchStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50
            foreach ($dsTask in @($dispatchState.tasks)) {
                if ($dsTask -and $dsTask.id -eq $TaskId -and $dsTask.task_data -and $dsTask.task_data.task) {
                    $task = $dsTask.task_data.task
                    break
                }
            }
        } catch {
            $task = $null
        }
    }

    $commentsResponse = $null
    try {
        if (-not $task) {
            $task = Invoke-MconApi -Method Get -Uri $taskUri -Token $authToken
        }
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

    try {
        Assert-MconAssignmentOrigin -OriginSessionKey $resolvedOriginSessionKey -TaskData $task
    } catch {
        return [ordered]@{
            ok            = $false
            phase         = 'origin_validation'
            error         = $_.Exception.Message
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            originSessionKey = $resolvedOriginSessionKey
            task          = Get-MconAssignTaskProjection -TaskData $task
        }
    }

    $runtimeOriginSessionKey = Resolve-MconAssignmentRuntimeSessionKey -LeadAgentId $LeadAgentId -OriginSessionKey $resolvedOriginSessionKey
    if ([string]::IsNullOrWhiteSpace($runtimeOriginSessionKey)) {
        return [ordered]@{
            ok               = $false
            phase            = 'origin_validation'
            error            = "Could not derive a lead runtime session key from origin '$resolvedOriginSessionKey'."
            taskId           = $TaskId
            workerAgentId    = $WorkerAgentId
            originSessionKey = $resolvedOriginSessionKey
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
    $openClawRoot = Split-Path -Parent $workspacePath
    $expectedWorkerWorkspacePath = Join-Path $openClawRoot "workspace-mc-$WorkerAgentId"
    $resolvedExpectedWorkerWorkspacePath = (Resolve-Path -LiteralPath $expectedWorkerWorkspacePath).Path
    if ($resolvedWorkerWorkspace -ne $resolvedExpectedWorkerWorkspacePath) {
        throw "Worker workspace mismatch for worker ${WorkerAgentId}: expected $resolvedExpectedWorkerWorkspacePath from the OpenClaw registry, got $resolvedWorkerWorkspace."
    }

    if (-not $OutputDir) {
        $OutputDir = Join-Path $workspacePath 'deliverables'
    }
    $resolvedOutputDir = New-MconDirectory -Path $OutputDir
    $bundlePath = Join-Path $resolvedOutputDir "$TaskId-bootstrap.json"

    if (-not $DiagnosticsDir) {
        $DiagnosticsDir = Join-Path $workspacePath 'diagnostics'
    }
    $resolvedDiagnosticsDir = New-MconDirectory -Path $DiagnosticsDir

    if (-not $MconScriptPath) {
        $MconScriptPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'mcon.ps1'
    }
    if (-not (Test-Path -LiteralPath $MconScriptPath)) {
        throw "mcon script not found: $MconScriptPath"
    }
    $resolvedMconScriptPath = (Resolve-Path -LiteralPath $MconScriptPath).Path

    $workerConfig = Resolve-MconOpenClawAgentConfig -WorkspacePath $resolvedWorkerWorkspace
    $workerName = $workerConfig.name
    $workerLegacyAgentName = [string]$($workerConfig.name).ToLower()
    $workerSpawnAgentId = $workerConfig.spawn_agent_id
    if ([string]::IsNullOrWhiteSpace($workerSpawnAgentId)) {
        throw "OpenClaw agent entry for workspace $resolvedWorkerWorkspace is missing a canonical spawn id."
    }
    $expectedWorkerSpawnAgentId = "mc-$WorkerAgentId"
    if ($workerSpawnAgentId -ne $expectedWorkerSpawnAgentId) {
        throw "Worker agent $WorkerAgentId resolved to OpenClaw agent id $workerSpawnAgentId, but the registry contract requires $expectedWorkerSpawnAgentId."
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

    $assignedAgentId = Get-MconNormalizedWorkerAgentId -AgentId $WorkerAgentId

    $currentAssignedAgentId = $null
    if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
        $currentAssignedAgentId = Get-MconNormalizedWorkerAgentId -AgentId ([string]$task.assigned_agent_id)
    }

    $currentStatus = $null
    if ($task.PSObject.Properties.Name -contains 'status' -and $task.status) {
        $currentStatus = ([string]$task.status).ToLowerInvariant()
    }

    $taskAlreadyActiveForWorker = ($currentAssignedAgentId -eq $assignedAgentId) -and ($currentStatus -and $currentStatus -ne 'inbox')

    if ($taskAlreadyActiveForWorker) {
        return [ordered]@{
            ok                   = $true
            mode                 = 'already_assigned'
            idempotent           = $true
            taskId               = $TaskId
            boardId              = $boardId
            workerAgentId        = $WorkerAgentId
            workerSpawnAgentId   = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath           = $bundlePath
            workerTaskDataPath   = $workerTaskDataPath
            sessionKey           = "agent:$workerSpawnAgentId`:task:$TaskId"
            finalTask            = Get-MconAssignTaskProjection -TaskData $task
        }
    }

    # Construct the deterministic worker task-scoped session key
    $workerTaskSessionKey = "agent:$workerSpawnAgentId`:task:$TaskId"

    $workerPrompt = @"
You are $workerName.

Read these first:
- Bootstrap bundle: $bundlePath
- Task data: $workerTaskDataPath

Work contract:
- Use the exact task bundle directory: $($taskBundlePaths.task_directory)
- Write the main deliverable inside: $($taskBundlePaths.deliverables_directory)
- Write the verification artifact to: $requiredVerificationArtifactPath
- After the assignment, post one concise task comment acknowledging the task and your short plan.
- Do not write outputs to the lead workspace root deliverables directory.
- Do not write outputs to your own workspace deliverables directory.
- When complete, post a handoff comment naming both deliverable paths explicitly and move the task to review.
- If blocked, run `mcon workflow blocker`  including the full detailed explanation in the message parameter for why you are blocked.
"@

    if ($DryRun) {
        $gatewayConfig = Get-MconOpenClawGatewayConfig -WorkspacePath $workspacePath
        $gatewayUri = "http://127.0.0.1:$($gatewayConfig.port)/v1/chat/completions"
        $predictedAssignmentPatch = [ordered]@{
            assigned_agent_id    = $WorkerAgentId
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
                    step         = 'direct_session_dispatch'
                    type         = 'gateway_chat'
                    mode         = 'foreground'
                    method       = 'POST'
                    uri          = $gatewayUri
                    headers      = @{
                        Authorization            = 'Bearer <gateway token>'
                        'x-openclaw-session-key' = $workerTaskSessionKey
                    }
                    body         = @{
                        model       = "openclaw/$workerSpawnAgentId"
                        temperature = 0
                        messages    = @(
                            @{
                                role    = 'user'
                                content = $workerPrompt
                            }
                        )
                    }
                    targetAgent  = $workerSpawnAgentId
                    sessionId    = $workerTaskSessionKey
                    message      = $workerPrompt
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

    # Send the worker prompt directly to the worker's task-scoped session
    $dispatchResult = $null
    try {
        $dispatchResult = Send-MconOpenClawSessionMessage `
            -WorkspacePath $workspacePath `
            -InvocationAgent $workerSpawnAgentId `
            -SessionKey $workerTaskSessionKey `
            -Message $workerPrompt `
            -TaskId $TaskId `
            -DispatchType 'assignment' `
            -TimeoutSec 300 `
            -Temperature 0
    } catch {
        $dispatchResult = [ordered]@{
            ok    = $false
            error = $_.Exception.Message
        }
    }

    # Patch the task with assignment and status using LOCAL_AUTH_TOKEN (user endpoint)
    $userTaskUri = "$baseUrl/api/v1/boards/$encodedBoardId/tasks/$encodedTaskId"
    $updatedTask = Invoke-MconLocalAuthApi -Method Patch -Uri $userTaskUri -Body @{
        assigned_agent_id = $assignedAgentId
        status            = 'in_progress'
    }

    return [ordered]@{
        ok                    = $true
        mode                  = 'assign'
        taskId                = $TaskId
        boardId               = $boardId
        workerAgentId         = $WorkerAgentId
        workerSpawnAgentId    = $workerSpawnAgentId
        workerLegacyAgentName = $workerLegacyAgentName
        bundlePath            = $bundlePath
        workerTaskDataPath    = $workerTaskDataPath
        sessionKey            = $workerTaskSessionKey
        dispatch              = $dispatchResult
        finalTask             = Get-MconAssignTaskProjection -TaskData $updatedTask
    }
}

Export-ModuleMember -Function Invoke-MconAssign, ConvertTo-MconCanonicalAssignmentSessionKey, Get-MconTaskSubagentUuid, Get-MconAssignTaskProjection, Get-MconNormalizedWorkerAgentId, Get-MconAssignTaskBundlePaths, New-MconBootstrapBundle, Write-MconWorkerTaskData, Get-MconAssignmentOriginSessionKey
