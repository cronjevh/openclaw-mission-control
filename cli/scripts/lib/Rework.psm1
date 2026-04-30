function Invoke-MconRework {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$WorkerAgentId,
        [Parameter(Mandatory)][string]$Message,
        [string]$MconScriptPath
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id
    $workspacePath = $Config.workspace_path

    $leadConfig = Resolve-MconLeadAgentConfig -BoardId $boardId
    if (-not $leadConfig) {
        return [ordered]@{
            ok     = $false
            phase  = 'config'
            error  = 'Board lead credentials are required for rework but were not found in the local keybag.'
            taskId = $TaskId
        }
    }
    $LeadAgentId = "lead-$boardId"

    $encodedBoardId = [uri]::EscapeDataString($boardId)
    $encodedTaskId = [uri]::EscapeDataString($TaskId)
    $taskUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/tasks/$encodedTaskId"
    $commentsUri = "$taskUri/comments"

    $task = $null
    $comments = @()
    try {
        $task = Invoke-MconApi -Method Get -Uri $taskUri -Token $authToken
        $commentsResponse = Invoke-MconApi -Method Get -Uri $commentsUri -Token $authToken
        if ($commentsResponse) {
            if ($commentsResponse.PSObject.Properties.Name -contains 'items') {
                $comments = @($commentsResponse.items | Where-Object { $null -ne $_ })
            } elseif ($commentsResponse.PSObject.Properties.Name -contains 'comments') {
                $comments = @($commentsResponse.comments | Where-Object { $null -ne $_ })
            }
        }
    } catch {
        return [ordered]@{
            ok            = $false
            phase         = 'task_fetch'
            error         = $_.Exception.Message
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            boardId       = $boardId
        }
    }

    $currentStatus = if ($task.PSObject.Properties.Name -contains 'status' -and $task.status) {
        ([string]$task.status).ToLowerInvariant()
    } else { '' }

    if ($currentStatus -notin @('review', 'inbox')) {
        return [ordered]@{
            ok            = $false
            phase         = 'precondition'
            error         = "Task must be in review or inbox status for rework. Current status: $currentStatus."
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            task          = Get-MconAssignTaskProjection -TaskData $task
        }
    }

    $currentSubagentUuid = Get-MconTaskSubagentUuid -TaskData $task

    $currentAssignedAgentId = $null
    if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
        $currentAssignedAgentId = Get-MconNormalizedWorkerAgentId -AgentId ([string]$task.assigned_agent_id)
    }

    $normalizedWorkerAgentId = Get-MconNormalizedWorkerAgentId -AgentId $WorkerAgentId
    if ($currentAssignedAgentId -and $currentAssignedAgentId -ne $normalizedWorkerAgentId) {
        return [ordered]@{
            ok            = $false
            phase         = 'precondition'
            error         = "Task was previously assigned to agent $currentAssignedAgentId, not $normalizedWorkerAgentId. Rework must target the same worker."
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            task          = Get-MconAssignTaskProjection -TaskData $task
        }
    }

    $openClawRoot = Split-Path -Parent $workspacePath
    $workerWorkspacePath = Join-Path $openClawRoot "workspace-mc-$WorkerAgentId"
    if (-not (Test-Path -LiteralPath $workerWorkspacePath)) {
        return [ordered]@{
            ok            = $false
            phase         = 'precondition'
            error         = "Worker workspace not found: $workerWorkspacePath"
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
        }
    }

    $workerConfig = Resolve-MconOpenClawAgentConfig -WorkspacePath $workerWorkspacePath
    $workerSpawnAgentId = $workerConfig.spawn_agent_id
    $workerLegacyAgentName = [string]($workerConfig.name).ToLower()

    $workerSessionAgentNames = @()
    foreach ($candidateAgentName in @($workerSpawnAgentId, $workerLegacyAgentName)) {
        if (-not [string]::IsNullOrWhiteSpace($candidateAgentName) -and ($workerSessionAgentNames -notcontains [string]$candidateAgentName)) {
            $workerSessionAgentNames += [string]$candidateAgentName
        }
    }

    $registeredSession = $null
    if (-not [string]::IsNullOrWhiteSpace($currentSubagentUuid)) {
        $registeredSession = Resolve-MconRegisteredSubagentSession `
            -OpenClawRoot $openClawRoot `
            -AgentName $workerSessionAgentNames `
            -SubagentUuid $currentSubagentUuid `
            -TaskId $TaskId
    }

    if (-not $registeredSession) {
        $registeredSession = Resolve-MconRegisteredSubagentSessionByTask `
            -OpenClawRoot $openClawRoot `
            -AgentName $workerSessionAgentNames `
            -TaskId $TaskId
    }

    if (-not $registeredSession) {
        return [ordered]@{
            ok            = $false
            phase         = 'session_lookup'
            error         = "Could not find a registered OpenClaw subagent session for task $TaskId for worker agent names ($($workerSessionAgentNames -join ', '))."
            taskId        = $TaskId
            workerAgentId = $WorkerAgentId
            subagent_uuid = $currentSubagentUuid
        }
    }

    $childSessionKey = [string]$registeredSession.childSessionKey
    $resolvedSubagentUuid = if ($registeredSession.PSObject.Properties.Name -contains 'subagentUuid') {
        [string]$registeredSession.subagentUuid
    } elseif ($registeredSession.PSObject.Properties.Name -contains 'subagent_uuid') {
        [string]$registeredSession.subagent_uuid
    } else {
        $currentSubagentUuid
    }

    if ([string]::IsNullOrWhiteSpace($currentSubagentUuid) -and -not [string]::IsNullOrWhiteSpace($resolvedSubagentUuid)) {
        $null = Invoke-MconApi -Method Patch -Uri $taskUri -Token $authToken -Body @{
            custom_field_values = @{ subagent_uuid = $resolvedSubagentUuid }
        }
    }
    $subagentAgentId = if ($registeredSession.PSObject.Properties.Name -contains 'registryAgentId') {
        [string]$registeredSession.registryAgentId
    } else {
        $workerSpawnAgentId
    }

    $taskBundlePaths = Get-MconAssignTaskBundlePaths -LeadWorkspacePath $workspacePath -TaskId $TaskId

    $workerTaskDataPath = Write-MconWorkerTaskData `
        -WorkerWorkspacePath $workerWorkspacePath `
        -BoardId $boardId `
        -LeadAgentId $LeadAgentId `
        -InvocationAgentId $LeadAgentId `
        -TaskData $task `
        -Comments $comments `
        -TaskBundlePaths $taskBundlePaths

    $bundleParams = @{
        BoardId             = $boardId
        TaskId              = $TaskId
        WorkerAgentId       = $WorkerAgentId
        WorkerName          = $workerConfig.name
        LeadWorkspacePath   = $workspacePath
        WorkerWorkspacePath = $workerWorkspacePath
        TaskData            = $task
    }
    if ($comments.Count -gt 0) {
        $bundleParams.Comments = $comments
    }
    $bundle = New-MconBootstrapBundle @bundleParams
    $bundlePath = Join-Path (Join-Path $workspacePath 'deliverables') "$TaskId-rework-bootstrap.json"
    $bundle | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bundlePath -Encoding UTF8

    $verificationArtifactPath = $bundle.lead_handoff.exact_output_contract.required_verification_artifact_path

    $reworkPrompt = @"
# REWORK DIRECTIVE

Task $TaskId verification failed and requires rework.

## Task Summary
- Task ID: $TaskId
- Title: $($task.title)
- Previous status: $currentStatus
- New status: in_progress (rework)

## Rework Feedback
$Message

## Updated Context Files
- Bootstrap bundle: $bundlePath
- Task data: $workerTaskDataPath

## Work Contract
- Use the exact task bundle directory: $($taskBundlePaths.task_directory)
- Write the main deliverable inside: $($taskBundlePaths.deliverables_directory)
- Write the verification artifact to: $verificationArtifactPath
- Do NOT start from scratch. Read the existing deliverables and fix only what needs fixing.
- After completing rework, post a handoff comment naming both deliverable paths explicitly and move the task to review.
- If blocked, run `mcon workflow blocker`  including the full detailed explanation in the message parameter for why you are blocked.
"@

    $dispatchResult = $null
    try {
        $diagnosticsDir = Join-Path $workspacePath 'diagnostics'
        if (-not (Test-Path -LiteralPath $diagnosticsDir)) {
            New-Item -ItemType Directory -Path $diagnosticsDir -Force | Out-Null
        }

        if (-not $MconScriptPath) {
            $MconScriptPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'mcon.ps1'
        }

        $deferredPayload = [ordered]@{
            workspace_path        = $workspacePath
            invocation_agent      = $subagentAgentId
            session_key           = $childSessionKey
            message               = $reworkPrompt
            task_id               = $TaskId
            dispatch_type         = 'rework'
            timeout_seconds       = 300
            temperature           = 0
            initial_delay_seconds = 0
        }

        $sessionDispatchDir = Join-Path (Join-Path $taskBundlePaths.evidence_directory 'session-dispatch') 'rework'
        $dispatchResult = Start-MconDeferredSessionDispatch `
            -WorkspacePath $workspacePath `
            -MconScriptPath $MconScriptPath `
            -DiagnosticsDir $sessionDispatchDir `
            -TaskId $TaskId `
            -Payload $deferredPayload
    } catch {
        $dispatchResult = [ordered]@{
            ok    = $false
            error = $_.Exception.Message
        }
    }

    $null = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $Message

    $updatedTask = Set-MconTaskStatus -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Status 'in_progress'

    return [ordered]@{
        ok                    = $true
        mode                  = 'rework'
        taskId                = $TaskId
        boardId               = $boardId
        workerAgentId         = $WorkerAgentId
        workerSpawnAgentId    = $workerSpawnAgentId
        workerLegacyAgentName = $workerLegacyAgentName
        subagent_uuid         = $resolvedSubagentUuid
        childSessionKey       = $childSessionKey
        bundlePath            = $bundlePath
        workerTaskDataPath    = $workerTaskDataPath
        dispatch              = $dispatchResult
        previousStatus        = $currentStatus
        resulting_task_status = $updatedTask.status
        task                  = Get-MconAssignTaskProjection -TaskData $updatedTask
    }
}

Export-ModuleMember -Function Invoke-MconRework
