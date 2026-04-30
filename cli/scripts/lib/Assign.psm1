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

    $childSessionMatch = [regex]::Match(
        $RawText,
        '"childSessionKey"\s*:\s*"(?<sessionKey>agent:[^"]+:subagent:[0-9a-fA-F-]{36})"'
    )
    if ($childSessionMatch.Success) {
        $runIdMatch = [regex]::Match($RawText, '"runId"\s*:\s*"([^"]+)"')
        return [pscustomobject]@{
            status          = 'accepted'
            childSessionKey = $childSessionMatch.Groups['sessionKey'].Value
            runId           = if ($runIdMatch.Success) { $runIdMatch.Groups[1].Value } else { $null }
            mode            = 'run'
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

function Get-MconDeferredAssignTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Payload,
        [Parameter(Mandatory)][string[]]$WorkerSessionAgentNames
    )

    $task = Invoke-MconApi -Method Get -Uri ([string]$Payload.task_uri) -Token ([string]$Payload.auth_token)
    $status = $null
    if ($task.PSObject.Properties.Name -contains 'status' -and $task.status) {
        $status = ([string]$task.status).ToLowerInvariant()
    }

    $assignedAgentId = $null
    if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
        $assignedAgentId = Get-MconNormalizedWorkerAgentId -AgentId ([string]$task.assigned_agent_id)
    }

    $targetAssignedAgentId = $null
    if ($Payload.PSObject.Properties.Name -contains 'assigned_agent_id' -and $Payload.assigned_agent_id) {
        $targetAssignedAgentId = Get-MconNormalizedWorkerAgentId -AgentId ([string]$Payload.assigned_agent_id)
    } elseif ($Payload.PSObject.Properties.Name -contains 'worker_agent_id' -and $Payload.worker_agent_id) {
        $targetAssignedAgentId = Get-MconNormalizedWorkerAgentId -AgentId ([string]$Payload.worker_agent_id)
    }

    $subagentUuid = Get-MconTaskSubagentUuid -TaskData $task
    $subagentUuidRecoveredFromSession = $false
    $registeredSession = $null
    if (-not [string]::IsNullOrWhiteSpace($subagentUuid)) {
        $registeredSession = Resolve-MconRegisteredSubagentSession `
            -OpenClawRoot ([string]$Payload.openclaw_root) `
            -AgentName $WorkerSessionAgentNames `
            -SubagentUuid $subagentUuid `
            -TaskId ([string]$Payload.task_id)
    }

    if (-not $registeredSession) {
        $registeredSession = Resolve-MconRegisteredSubagentSessionByTask `
            -OpenClawRoot ([string]$Payload.openclaw_root) `
            -AgentName $WorkerSessionAgentNames `
            -TaskId ([string]$Payload.task_id)

        if ($registeredSession -and [string]::IsNullOrWhiteSpace($subagentUuid)) {
            $subagentUuid = [string]$registeredSession.subagent_uuid
            $subagentUuidRecoveredFromSession = -not [string]::IsNullOrWhiteSpace($subagentUuid)
        }
    }

    $recoverAssignment = (
        $registeredSession -and
        -not [string]::IsNullOrWhiteSpace($subagentUuid) -and
        $status -eq 'inbox'
    )

    $reason = $null
    if ($recoverAssignment) {
        $reason = 'task_has_existing_registered_session'
    } elseif ($subagentUuidRecoveredFromSession) {
        $reason = 'task_has_existing_registered_session'
    } elseif (-not [string]::IsNullOrWhiteSpace($subagentUuid)) {
        $reason = 'task_already_has_subagent_uuid'
    } elseif (-not [string]::IsNullOrWhiteSpace($status) -and $status -ne 'inbox') {
        $reason = "task_status_is_$status"
    } elseif (
        -not [string]::IsNullOrWhiteSpace($assignedAgentId) -and
        -not [string]::IsNullOrWhiteSpace($targetAssignedAgentId) -and
        $assignedAgentId -ne $targetAssignedAgentId
    ) {
        $reason = 'task_reassigned_to_different_agent'
    }

    return [ordered]@{
        task               = $task
        status             = $status
        assigned_agent_id  = $assignedAgentId
        target_agent_id    = $targetAssignedAgentId
        subagent_uuid      = $subagentUuid
        registered_session = $registeredSession
        recover_assignment = $recoverAssignment
        spawn_needed       = [string]::IsNullOrWhiteSpace($reason)
        reason             = $reason
    }
}

function Resolve-MconRegisteredSubagentSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OpenClawRoot,
        [Parameter(Mandatory)][string[]]$AgentName,
        [Parameter(Mandatory)][string]$SubagentUuid,
        [string]$TaskId
    )

    $candidateAgentNames = @()
    foreach ($candidateAgentName in @($AgentName)) {
        if (-not [string]::IsNullOrWhiteSpace($candidateAgentName) -and ($candidateAgentNames -notcontains [string]$candidateAgentName)) {
            $candidateAgentNames += [string]$candidateAgentName
        }
    }

    if ($candidateAgentNames.Count -eq 0 -or [string]::IsNullOrWhiteSpace($SubagentUuid)) {
        return $null
    }

    foreach ($candidateAgentName in $candidateAgentNames) {
        $sessionKey = "agent:$candidateAgentName:subagent:$SubagentUuid"
        $sessionsPath = Join-Path $OpenClawRoot "agents/$candidateAgentName/sessions/sessions.json"
        if (-not (Test-Path -LiteralPath $sessionsPath)) {
            continue
        }

        try {
            $sessions = Get-Content -LiteralPath $sessionsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
        } catch {
            continue
        }

        if (-not $sessions -or -not ($sessions.PSObject.Properties.Name -contains $sessionKey)) {
            continue
        }

        $entry = $sessions.$sessionKey
        if ($TaskId) {
            $expectedLabel = "task:$TaskId"
            $expectedTaskSuffix = ":task:$TaskId"
            $matchesTask = $false

            if ($entry -and ($entry.PSObject.Properties.Name -contains 'label') -and ([string]$entry.label -eq $expectedLabel)) {
                $matchesTask = $true
            }

            if (
                -not $matchesTask -and
                $entry -and
                ($entry.PSObject.Properties.Name -contains 'spawnedBy') -and
                $entry.spawnedBy -and
                ([string]$entry.spawnedBy).EndsWith($expectedTaskSuffix)
            ) {
                $matchesTask = $true
            }

            if (-not $matchesTask) {
                continue
            }
        }

        return [ordered]@{
            childSessionKey = $sessionKey
            sessionId       = if ($entry -and ($entry.PSObject.Properties.Name -contains 'sessionId')) { [string]$entry.sessionId } else { $null }
            label           = if ($entry -and ($entry.PSObject.Properties.Name -contains 'label')) { [string]$entry.label } else { $null }
            spawnedBy       = if ($entry -and ($entry.PSObject.Properties.Name -contains 'spawnedBy')) { [string]$entry.spawnedBy } else { $null }
            registryAgentId = $candidateAgentName
        }
    }

    return $null
}

function Resolve-MconRegisteredSubagentSessionByTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OpenClawRoot,
        [Parameter(Mandatory)][string[]]$AgentName,
        [Parameter(Mandatory)][string]$TaskId
    )

    $candidateAgentNames = @()
    foreach ($candidateAgentName in @($AgentName)) {
        if (-not [string]::IsNullOrWhiteSpace($candidateAgentName) -and ($candidateAgentNames -notcontains [string]$candidateAgentName)) {
            $candidateAgentNames += [string]$candidateAgentName
        }
    }

    if ($candidateAgentNames.Count -eq 0 -or [string]::IsNullOrWhiteSpace($TaskId)) {
        return $null
    }

    $expectedLabel = "task:$TaskId"
    $expectedTaskSuffix = ":task:$TaskId"
    $bestMatch = $null
    $bestUpdatedAt = [Int64]::MinValue

    foreach ($candidateAgentName in $candidateAgentNames) {
        $sessionsPath = Join-Path $OpenClawRoot "agents/$candidateAgentName/sessions/sessions.json"
        if (-not (Test-Path -LiteralPath $sessionsPath)) {
            continue
        }

        try {
            $sessions = Get-Content -LiteralPath $sessionsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
        } catch {
            continue
        }

        if (-not $sessions) {
            continue
        }

        foreach ($property in $sessions.PSObject.Properties) {
            $sessionKey = [string]$property.Name
            if ($sessionKey -notlike "agent:$candidateAgentName:subagent:*") {
                continue
            }

            $entry = $property.Value
            $matchesTask = $false

            if ($entry -and ($entry.PSObject.Properties.Name -contains 'label') -and ([string]$entry.label -eq $expectedLabel)) {
                $matchesTask = $true
            }

            if (
                -not $matchesTask -and
                $entry -and
                ($entry.PSObject.Properties.Name -contains 'spawnedBy') -and
                $entry.spawnedBy -and
                ([string]$entry.spawnedBy).EndsWith($expectedTaskSuffix)
            ) {
                $matchesTask = $true
            }

            if (-not $matchesTask) {
                continue
            }

            $updatedAt = 0
            if ($entry -and ($entry.PSObject.Properties.Name -contains 'updatedAt') -and $entry.updatedAt) {
                try {
                    $updatedAt = [Int64]$entry.updatedAt
                } catch {
                    $updatedAt = 0
                }
            }

            if ($bestMatch -and $updatedAt -lt $bestUpdatedAt) {
                continue
            }

            $subagentUuid = $null
            $uuidMatch = [regex]::Match($sessionKey, ':subagent:([0-9a-fA-F-]{36})$')
            if ($uuidMatch.Success) {
                $subagentUuid = $uuidMatch.Groups[1].Value
            }

            $bestMatch = [ordered]@{
                childSessionKey = $sessionKey
                sessionId       = if ($entry -and ($entry.PSObject.Properties.Name -contains 'sessionId')) { [string]$entry.sessionId } else { $null }
                label           = if ($entry -and ($entry.PSObject.Properties.Name -contains 'label')) { [string]$entry.label } else { $null }
                spawnedBy       = if ($entry -and ($entry.PSObject.Properties.Name -contains 'spawnedBy')) { [string]$entry.spawnedBy } else { $null }
                registryAgentId = $candidateAgentName
                subagent_uuid   = $subagentUuid
                updatedAt       = $updatedAt
            }
            $bestUpdatedAt = $updatedAt
        }
    }

    return $bestMatch
}

function Wait-MconRegisteredSubagentSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OpenClawRoot,
        [Parameter(Mandatory)][string[]]$AgentName,
        [Parameter(Mandatory)][string]$SubagentUuid,
        [string]$TaskId,
        [int]$MaxAttempts = 20,
        [int]$DelayMilliseconds = 500
    )

    for ($attempt = 1; $attempt -le [Math]::Max(1, $MaxAttempts); $attempt++) {
        $session = Resolve-MconRegisteredSubagentSession -OpenClawRoot $OpenClawRoot -AgentName $AgentName -SubagentUuid $SubagentUuid -TaskId $TaskId
        if ($session) {
            return $session
        }

        if ($attempt -lt $MaxAttempts -and $DelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
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

function Get-MconAssignWorkflowPaths {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $workflowDir = Join-Path $WorkspacePath '.openclaw/workflows'
    $jobsDir = Join-Path (Join-Path $WorkspacePath 'diagnostics') 'assign-spawn-jobs'
    if (-not (Test-Path -LiteralPath $workflowDir)) {
        New-Item -ItemType Directory -Path $workflowDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $jobsDir)) {
        New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null
    }

    return [ordered]@{
        workflow_dir = $workflowDir
        jobs_dir     = $jobsDir
        latest_path  = Join-Path $workflowDir '.assign-state-latest.json'
        log_path     = Join-Path $workflowDir 'assign-recovery.log'
    }
}

function Write-MconAssignWorkflowLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    $timestamp = (Get-Date).ToString('o')
    "[$timestamp] $Message" | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Write-MconAssignWorkflowState {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$State,
        [hashtable]$Fields = @{}
    )

    $paths = Get-MconAssignWorkflowPaths -WorkspacePath $WorkspacePath
    $record = [ordered]@{
        state      = $State
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    }

    foreach ($key in $Fields.Keys) {
        $record[$key] = $Fields[$key]
    }

    $tmpPath = "$($paths.latest_path).tmp"
    $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmpPath -Encoding UTF8
    Move-Item -LiteralPath $tmpPath -Destination $paths.latest_path -Force

    $summary = @("state=$State")
    foreach ($key in @('task_id', 'job_id', 'phase', 'reason', 'result_path', 'payload_path')) {
        if ($record.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$record[$key])) {
            $summary += "$key=$($record[$key])"
        }
    }
    Write-MconAssignWorkflowLog -Path $paths.log_path -Message ($summary -join ' ')
    return [pscustomobject]$record
}

function Test-MconProcessAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }

    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function New-MconDeferredAssignWrapperErrorResult {
    param(
        [Parameter(Mandatory)][string]$PayloadPath,
        [Parameter(Mandatory)][string]$ErrorMessage
    )

    $payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $resultPath = [string]$payload.result_path
    $errorResult = [ordered]@{
        ok                    = $false
        phase                 = 'deferred_assign_wrapper'
        error                 = $ErrorMessage
        taskId                = if ($payload.PSObject.Properties.Name -contains 'task_id') { [string]$payload.task_id } else { $null }
        boardId               = if ($payload.PSObject.Properties.Name -contains 'board_id') { [string]$payload.board_id } else { $null }
        workerAgentId         = if ($payload.PSObject.Properties.Name -contains 'worker_agent_id') { [string]$payload.worker_agent_id } else { $null }
        workerSpawnAgentId    = if ($payload.PSObject.Properties.Name -contains 'worker_spawn_agent_id') { [string]$payload.worker_spawn_agent_id } else { $null }
        workerLegacyAgentName = if ($payload.PSObject.Properties.Name -contains 'worker_legacy_agent_name') { [string]$payload.worker_legacy_agent_name } else { $null }
        bundlePath            = if ($payload.PSObject.Properties.Name -contains 'bundle_path') { [string]$payload.bundle_path } else { $null }
        workerTaskDataPath    = if ($payload.PSObject.Properties.Name -contains 'worker_task_data_path') { [string]$payload.worker_task_data_path } else { $null }
        deferredSpawn         = [ordered]@{
            jobId       = if ($payload.PSObject.Properties.Name -contains 'job_id') { [string]$payload.job_id } else { $null }
            pid         = if ($payload.PSObject.Properties.Name -contains 'pid') { $payload.pid } else { $null }
            payloadPath = $PayloadPath
            resultPath  = $resultPath
            stdoutLog   = if ($payload.PSObject.Properties.Name -contains 'stdout_log') { [string]$payload.stdout_log } else { $null }
            stderrLog   = if ($payload.PSObject.Properties.Name -contains 'stderr_log') { [string]$payload.stderr_log } else { $null }
            attempts    = @()
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($resultPath)) {
        Write-MconDiagnosticsJson -Path $resultPath -Data $errorResult | Out-Null
    }
    if ($payload.PSObject.Properties.Name -contains 'workspace_path' -and -not [string]::IsNullOrWhiteSpace([string]$payload.workspace_path)) {
        Write-MconAssignWorkflowState `
            -WorkspacePath ([string]$payload.workspace_path) `
            -State 'wrapper_failed' `
            -Fields @{
                task_id     = $errorResult.taskId
                job_id      = $errorResult.deferredSpawn.jobId
                phase       = $errorResult.phase
                reason      = $ErrorMessage
                payload_path = $PayloadPath
                result_path = $resultPath
            } | Out-Null
    }

    return $errorResult
}

function Invoke-MconDeferredAssignRecoverySweep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [int]$StaleAfterMinutes = 3,
        [string]$ExcludePayloadPath = $null
    )

    $paths = Get-MconAssignWorkflowPaths -WorkspacePath $WorkspacePath
    $now = Get-Date
    $staleCutoff = $now.AddMinutes(-1 * [Math]::Max(1, $StaleAfterMinutes))
    $recovered = @()

    $payloadFiles = @(
        Get-ChildItem -LiteralPath $paths.jobs_dir -Filter '*-payload.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )

    $seenTaskIds = @{}

    foreach ($payloadFile in $payloadFiles) {
        if ($ExcludePayloadPath -and $payloadFile.FullName -eq $ExcludePayloadPath) {
            continue
        }
        if ($payloadFile.LastWriteTimeUtc -gt $staleCutoff) {
            continue
        }

        $taskId = $null
        try {
            $payload = Get-Content -LiteralPath $payloadFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
            $taskId = if ($payload.PSObject.Properties.Name -contains 'task_id') { [string]$payload.task_id } else { $null }
        } catch {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($taskId) -and $seenTaskIds.ContainsKey($taskId)) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($taskId)) {
            $seenTaskIds[$taskId] = $true
        }

        $resultPath = if ($payload -and ($payload.PSObject.Properties.Name -contains 'result_path')) { [string]$payload.result_path } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($resultPath) -and (Test-Path -LiteralPath $resultPath)) {
            continue
        }

        $jobId = if ($payload -and ($payload.PSObject.Properties.Name -contains 'job_id')) { [string]$payload.job_id } else { $null }
        $processId = if ($payload -and ($payload.PSObject.Properties.Name -contains 'pid')) { [int]$payload.pid } else { 0 }
        if (Test-MconProcessAlive -ProcessId $processId) {
            Write-MconAssignWorkflowState -WorkspacePath $WorkspacePath -State 'recovery_skipped_process_alive' -Fields @{
                task_id      = $taskId
                job_id       = $jobId
                phase        = 'recovery_sweep'
                reason       = "deferred assign worker pid $processId is still running"
                payload_path = $payloadFile.FullName
                result_path  = $resultPath
            } | Out-Null
            continue
        }

        Write-MconAssignWorkflowState -WorkspacePath $WorkspacePath -State 'recovery_replaying_orphan' -Fields @{
            task_id      = $taskId
            job_id       = $jobId
            phase        = 'recovery_sweep'
            reason       = 'payload exists without result and worker process is not running'
            payload_path = $payloadFile.FullName
            result_path  = $resultPath
        } | Out-Null

        try {
            $result = Invoke-MconDeferredAssignSpawn -PayloadPath $payloadFile.FullName
        } catch {
            $result = New-MconDeferredAssignWrapperErrorResult -PayloadPath $payloadFile.FullName -ErrorMessage $_.Exception.Message
        }

        $recovered += [pscustomobject]@{
            taskId      = $taskId
            jobId       = $jobId
            payloadPath = $payloadFile.FullName
            resultPath  = $resultPath
            ok          = if ($result -and ($result.PSObject.Properties.Name -contains 'ok')) { [bool]$result.ok } else { $false }
            mode        = if ($result -and ($result.PSObject.Properties.Name -contains 'mode')) { [string]$result.mode } else { $null }
            phase       = if ($result -and ($result.PSObject.Properties.Name -contains 'phase')) { [string]$result.phase } else { $null }
            error       = if ($result -and ($result.PSObject.Properties.Name -contains 'error')) { [string]$result.error } else { $null }
        }
    }

    if ($recovered.Count -gt 0) {
        Write-MconAssignWorkflowState -WorkspacePath $WorkspacePath -State 'recovery_completed' -Fields @{
            phase  = 'recovery_sweep'
            reason = "replayed $($recovered.Count) orphaned deferred assign job(s)"
        } | Out-Null
    }

    return ,$recovered
}

function Start-MconDeferredAssignSpawn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$MconScriptPath,
        [Parameter(Mandatory)][string]$DiagnosticsDir,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][hashtable]$Payload
    )

    $jobsDir = New-MconDirectory -Path (Join-Path $DiagnosticsDir 'assign-spawn-jobs')
    $jobId = [guid]::NewGuid().Guid
    $payloadPath = Join-Path $jobsDir "$TaskId-$jobId-payload.json"
    $resultPath = Join-Path $jobsDir "$TaskId-$jobId-result.json"
    $stdoutLog = Join-Path $jobsDir "$TaskId-$jobId-stdout.log"
    $stderrLog = Join-Path $jobsDir "$TaskId-$jobId-stderr.log"

    $Payload['job_id'] = $jobId
    $Payload['payload_path'] = $payloadPath
    $Payload['result_path'] = $resultPath
    $Payload['stdout_log'] = $stdoutLog
    $Payload['stderr_log'] = $stderrLog
    $Payload['created_at'] = (Get-Date).ToUniversalTime().ToString('o')

    Write-MconDiagnosticsJson -Path $payloadPath -Data $Payload | Out-Null

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $process = Start-Process `
        -FilePath $pwshPath `
        -ArgumentList @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $MconScriptPath, 'workflow', 'assign', '--process-deferred-spawn', '--payload', $payloadPath) `
        -WorkingDirectory $WorkspacePath `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    $Payload['pid'] = $process.Id
    Write-MconDiagnosticsJson -Path $payloadPath -Data $Payload | Out-Null
    Write-MconAssignWorkflowState -WorkspacePath $WorkspacePath -State 'queued' -Fields @{
        task_id      = $TaskId
        job_id       = $jobId
        phase        = 'launch'
        reason       = 'deferred assign worker launched'
        payload_path = $payloadPath
        result_path  = $resultPath
        pid          = $process.Id
    } | Out-Null

    return [ordered]@{
        queued       = $true
        jobId        = $jobId
        pid          = $process.Id
        payloadPath  = $payloadPath
        resultPath   = $resultPath
        stdoutLog    = $stdoutLog
        stderrLog    = $stderrLog
    }
}

function Invoke-MconDeferredAssignSpawn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PayloadPath
    )

    $payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $resultPath = [string]$payload.result_path
    $attempts = @()
    $spawnResponse = $null
    $spawnRaw = $null
    $spawnResult = $null
    $childSessionKey = $null
    $subagentUuid = $null
    $registeredSpawnSession = $null
    $assignmentPatch = $null
    $statusPatch = $null
    $finalTask = $null
    $spawnRegistryConfirmed = $false
    $warnings = @()
    $workerSessionAgentNames = @()
    if ($payload.PSObject.Properties.Name -contains 'workspace_path' -and -not [string]::IsNullOrWhiteSpace([string]$payload.workspace_path)) {
        Write-MconAssignWorkflowState -WorkspacePath ([string]$payload.workspace_path) -State 'processing' -Fields @{
            task_id      = if ($payload.PSObject.Properties.Name -contains 'task_id') { [string]$payload.task_id } else { $null }
            job_id       = if ($payload.PSObject.Properties.Name -contains 'job_id') { [string]$payload.job_id } else { $null }
            phase        = 'deferred_assign_spawn'
            reason       = 'processing payload'
            payload_path = $PayloadPath
            result_path  = $resultPath
        } | Out-Null
    }

    try {
        foreach ($candidateAgentName in @([string]$payload.worker_spawn_agent_id, [string]$payload.worker_legacy_agent_name)) {
            if (-not [string]::IsNullOrWhiteSpace($candidateAgentName) -and ($workerSessionAgentNames -notcontains [string]$candidateAgentName)) {
                $workerSessionAgentNames += [string]$candidateAgentName
            }
        }

        $initialDelaySeconds = if ($payload.PSObject.Properties.Name -contains 'initial_delay_seconds') { [int]$payload.initial_delay_seconds } else { 2 }
        $retryDelaySeconds = if ($payload.PSObject.Properties.Name -contains 'retry_delay_seconds') { [int]$payload.retry_delay_seconds } else { 5 }
        $maxAttempts = if ($payload.PSObject.Properties.Name -contains 'max_attempts') { [int]$payload.max_attempts } else { 6 }
        $timeoutSeconds = if ($payload.PSObject.Properties.Name -contains 'timeout_seconds') { [int]$payload.timeout_seconds } else { 120 }

        if ($initialDelaySeconds -gt 0) {
            Start-Sleep -Seconds $initialDelaySeconds
        }

        for ($attempt = 1; $attempt -le [Math]::Max(1, $maxAttempts); $attempt++) {
            $attemptRecord = [ordered]@{
                attempt    = $attempt
                started_at = (Get-Date).ToUniversalTime().ToString('o')
            }

            try {
                $liveTaskState = Get-MconDeferredAssignTaskState -Payload $payload -WorkerSessionAgentNames $workerSessionAgentNames
                if ($liveTaskState.recover_assignment) {
                    $childSessionKey = if ($liveTaskState.registered_session) { [string]$liveTaskState.registered_session.childSessionKey } else { $null }
                    $subagentUuid = [string]$liveTaskState.subagent_uuid
                    if ([string]::IsNullOrWhiteSpace($childSessionKey) -or [string]::IsNullOrWhiteSpace($subagentUuid)) {
                        throw 'Deferred assign recovery found an existing registered session but could not resolve its childSessionKey or subagent_uuid.'
                    }

                    $combinedPatch = Invoke-MconApi -Method Patch -Uri ([string]$payload.task_uri) -Token ([string]$payload.auth_token) -Body @{
                        assigned_agent_id   = [string]$payload.assigned_agent_id
                        status              = 'in_progress'
                        custom_field_values = @{ subagent_uuid = $subagentUuid }
                    }
                    $assignmentPatch = $combinedPatch
                    $statusPatch = $combinedPatch
                    $finalTask = Invoke-MconApi -Method Get -Uri ([string]$payload.task_uri) -Token ([string]$payload.auth_token)

                    $attemptRecord['outcome'] = 'recovered_existing_session'
                    $attemptRecord['reason'] = [string]$liveTaskState.reason
                    $attemptRecord['childSessionKey'] = $childSessionKey
                    $attemptRecord['completed_at'] = (Get-Date).ToUniversalTime().ToString('o')
                    $attempts += [pscustomobject]$attemptRecord

                    $recoveredResult = [ordered]@{
                        ok                    = $true
                        mode                  = 'assign_recovered'
                        async                 = $true
                        taskId                = [string]$payload.task_id
                        boardId               = [string]$payload.board_id
                        workerAgentId         = [string]$payload.worker_agent_id
                        workerSpawnAgentId    = [string]$payload.worker_spawn_agent_id
                        workerLegacyAgentName = [string]$payload.worker_legacy_agent_name
                        bundlePath            = [string]$payload.bundle_path
                        workerTaskDataPath    = [string]$payload.worker_task_data_path
                        deferredSpawn         = [ordered]@{
                            jobId       = [string]$payload.job_id
                            payloadPath = [string]$payload.payload_path
                            resultPath  = $resultPath
                            stdoutLog   = [string]$payload.stdout_log
                            stderrLog   = [string]$payload.stderr_log
                            completedAt = (Get-Date).ToUniversalTime().ToString('o')
                            attempts    = @($attempts)
                        }
                        spawn                 = [ordered]@{
                            status            = 'existing'
                            reason            = [string]$liveTaskState.reason
                            childSessionKey   = $childSessionKey
                            runId             = $null
                            mode              = 'existing'
                            subagent_uuid     = $subagentUuid
                            promptSent        = $false
                            registryConfirmed = $true
                            registeredSession = $liveTaskState.registered_session
                        }
                        warnings              = @(
                            'Recovered the board assignment from an already-registered subagent session without sending a new spawn prompt.'
                        )
                        patches               = [ordered]@{
                            assignment = $assignmentPatch
                            status     = $statusPatch
                        }
                        finalTask             = Get-MconAssignTaskProjection -TaskData $finalTask
                    }

                    Write-MconDiagnosticsJson -Path $resultPath -Data $recoveredResult | Out-Null
                    Write-MconAssignWorkflowState -WorkspacePath ([string]$payload.workspace_path) -State 'recovered' -Fields @{
                        task_id      = [string]$payload.task_id
                        job_id       = [string]$payload.job_id
                        phase        = 'deferred_assign_spawn'
                        reason       = [string]$liveTaskState.reason
                        payload_path = $PayloadPath
                        result_path  = $resultPath
                    } | Out-Null
                    return $recoveredResult
                }

                if (-not $liveTaskState.spawn_needed) {
                    $attemptRecord['outcome'] = 'superseded'
                    $attemptRecord['reason'] = [string]$liveTaskState.reason
                    $attemptRecord['completed_at'] = (Get-Date).ToUniversalTime().ToString('o')
                    $attempts += [pscustomobject]$attemptRecord

                    $supersededResult = [ordered]@{
                        ok                    = $true
                        mode                  = 'assign_superseded'
                        async                 = $true
                        taskId                = [string]$payload.task_id
                        boardId               = [string]$payload.board_id
                        workerAgentId         = [string]$payload.worker_agent_id
                        workerSpawnAgentId    = [string]$payload.worker_spawn_agent_id
                        workerLegacyAgentName = [string]$payload.worker_legacy_agent_name
                        bundlePath            = [string]$payload.bundle_path
                        workerTaskDataPath    = [string]$payload.worker_task_data_path
                        deferredSpawn         = [ordered]@{
                            jobId       = [string]$payload.job_id
                            payloadPath = [string]$payload.payload_path
                            resultPath  = $resultPath
                            stdoutLog   = [string]$payload.stdout_log
                            stderrLog   = [string]$payload.stderr_log
                            completedAt = (Get-Date).ToUniversalTime().ToString('o')
                            attempts    = @($attempts)
                        }
                        spawn                 = [ordered]@{
                            status            = if ($liveTaskState.registered_session) { 'existing' } else { 'skipped' }
                            reason            = [string]$liveTaskState.reason
                            childSessionKey   = if ($liveTaskState.registered_session) { [string]$liveTaskState.registered_session.childSessionKey } else { $null }
                            runId             = $null
                            mode              = if ($liveTaskState.registered_session) { 'existing' } else { 'skipped' }
                            subagent_uuid     = [string]$liveTaskState.subagent_uuid
                            promptSent        = $false
                            registryConfirmed = ($null -ne $liveTaskState.registered_session)
                            registeredSession = if ($liveTaskState.registered_session) { $liveTaskState.registered_session } else { $null }
                        }
                        finalTask             = Get-MconAssignTaskProjection -TaskData $liveTaskState.task
                    }

                    Write-MconDiagnosticsJson -Path $resultPath -Data $supersededResult | Out-Null
                    Write-MconAssignWorkflowState -WorkspacePath ([string]$payload.workspace_path) -State 'superseded' -Fields @{
                        task_id      = [string]$payload.task_id
                        job_id       = [string]$payload.job_id
                        phase        = 'deferred_assign_spawn'
                        reason       = [string]$liveTaskState.reason
                        payload_path = $PayloadPath
                        result_path  = $resultPath
                    } | Out-Null
                    return $supersededResult
                }

                $spawnResponse = Send-MconOpenClawSessionMessage `
                    -WorkspacePath ([string]$payload.workspace_path) `
                    -InvocationAgent ([string]$payload.lead_agent_id) `
                    -Message ([string]$payload.spawn_prompt) `
                    -SessionKey ([string]$payload.runtime_origin_session_key) `
                    -TimeoutSec $timeoutSeconds `
                    -Temperature 0

                $spawnRaw = Resolve-MconGatewayChatResponseText -Response $spawnResponse
                $spawnResult = Resolve-MconSpawnResult -RawText $spawnRaw
                $childSessionKey = [string]$spawnResult.childSessionKey
                $attemptRecord['outcome'] = 'accepted'
                $attemptRecord['childSessionKey'] = $childSessionKey
                $attemptRecord['completed_at'] = (Get-Date).ToUniversalTime().ToString('o')
                $attempts += [pscustomobject]$attemptRecord
                break
            } catch {
                $attemptRecord['outcome'] = 'retryable_failure'
                $attemptRecord['error'] = $_.Exception.Message
                $attemptRecord['completed_at'] = (Get-Date).ToUniversalTime().ToString('o')
                $attempts += [pscustomobject]$attemptRecord

                if ($attempt -ge $maxAttempts) {
                    throw
                }

                if ($retryDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $retryDelaySeconds
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($childSessionKey)) {
            throw 'Deferred spawn did not return childSessionKey.'
        }

        $uuidMatch = [regex]::Match($childSessionKey, ':subagent:([0-9a-fA-F-]{36})$')
        if (-not $uuidMatch.Success) {
            throw "Deferred spawn returned unexpected childSessionKey format: $childSessionKey"
        }
        $subagentUuid = $uuidMatch.Groups[1].Value

        $registeredSpawnSession = Wait-MconRegisteredSubagentSession `
            -OpenClawRoot ([string]$payload.openclaw_root) `
            -AgentName $workerSessionAgentNames `
            -SubagentUuid $subagentUuid `
            -TaskId ([string]$payload.task_id)
        $spawnRegistryConfirmed = ($null -ne $registeredSpawnSession)
        if (-not $spawnRegistryConfirmed) {
            $warnings += "Mission Control could not confirm the spawned session in OpenClaw's registry within the wait window. Assignment continued based on the returned childSessionKey."
        }

        $combinedPatch = Invoke-MconApi -Method Patch -Uri ([string]$payload.task_uri) -Token ([string]$payload.auth_token) -Body @{
            assigned_agent_id   = [string]$payload.assigned_agent_id
            status              = 'in_progress'
            custom_field_values = @{ subagent_uuid = $subagentUuid }
        }
        $assignmentPatch = $combinedPatch
        $statusPatch = $combinedPatch

        $finalTask = Invoke-MconApi -Method Get -Uri ([string]$payload.task_uri) -Token ([string]$payload.auth_token)

        $result = [ordered]@{
            ok                   = $true
            mode                 = 'assign'
            async                = $true
            taskId               = [string]$payload.task_id
            boardId              = [string]$payload.board_id
            workerAgentId        = [string]$payload.worker_agent_id
            workerSpawnAgentId   = [string]$payload.worker_spawn_agent_id
            workerLegacyAgentName = [string]$payload.worker_legacy_agent_name
            bundlePath           = [string]$payload.bundle_path
            workerTaskDataPath   = [string]$payload.worker_task_data_path
            deferredSpawn        = [ordered]@{
                jobId       = [string]$payload.job_id
                payloadPath = [string]$payload.payload_path
                resultPath  = $resultPath
                stdoutLog   = [string]$payload.stdout_log
                stderrLog   = [string]$payload.stderr_log
                completedAt = (Get-Date).ToUniversalTime().ToString('o')
                attempts    = @($attempts)
            }
            spawn                = [ordered]@{
                status            = $spawnResult.status
                childSessionKey   = $childSessionKey
                runId             = $spawnResult.runId
                mode              = $spawnResult.mode
                subagent_uuid     = $subagentUuid
                promptSent        = $true
                registryConfirmed = $spawnRegistryConfirmed
                registeredSession = if ($registeredSpawnSession) { $registeredSpawnSession } else { $null }
            }
            warnings             = @($warnings)
            patches              = [ordered]@{
                assignment = $assignmentPatch
                status     = $statusPatch
            }
            finalTask            = Get-MconAssignTaskProjection -TaskData $finalTask
        }

        Write-MconDiagnosticsJson -Path $resultPath -Data $result | Out-Null
        Write-MconAssignWorkflowState -WorkspacePath ([string]$payload.workspace_path) -State 'completed' -Fields @{
            task_id      = [string]$payload.task_id
            job_id       = [string]$payload.job_id
            phase        = 'deferred_assign_spawn'
            reason       = 'spawn accepted and task patched'
            payload_path = $PayloadPath
            result_path  = $resultPath
        } | Out-Null
        return $result
    } catch {
        $errorResult = [ordered]@{
            ok                    = $false
            phase                 = 'deferred_assign_spawn'
            error                 = $_.Exception.Message
            taskId                = if ($payload.PSObject.Properties.Name -contains 'task_id') { [string]$payload.task_id } else { $null }
            boardId               = if ($payload.PSObject.Properties.Name -contains 'board_id') { [string]$payload.board_id } else { $null }
            workerAgentId         = if ($payload.PSObject.Properties.Name -contains 'worker_agent_id') { [string]$payload.worker_agent_id } else { $null }
            workerSpawnAgentId    = if ($payload.PSObject.Properties.Name -contains 'worker_spawn_agent_id') { [string]$payload.worker_spawn_agent_id } else { $null }
            workerLegacyAgentName = if ($payload.PSObject.Properties.Name -contains 'worker_legacy_agent_name') { [string]$payload.worker_legacy_agent_name } else { $null }
            bundlePath            = if ($payload.PSObject.Properties.Name -contains 'bundle_path') { [string]$payload.bundle_path } else { $null }
            workerTaskDataPath    = if ($payload.PSObject.Properties.Name -contains 'worker_task_data_path') { [string]$payload.worker_task_data_path } else { $null }
            deferredSpawn         = [ordered]@{
                jobId       = if ($payload.PSObject.Properties.Name -contains 'job_id') { [string]$payload.job_id } else { $null }
                payloadPath = $PayloadPath
                resultPath  = $resultPath
                stdoutLog   = if ($payload.PSObject.Properties.Name -contains 'stdout_log') { [string]$payload.stdout_log } else { $null }
                stderrLog   = if ($payload.PSObject.Properties.Name -contains 'stderr_log') { [string]$payload.stderr_log } else { $null }
                attempts    = @($attempts)
            }
            spawnOutput           = if ($spawnResponse) { $spawnResponse | ConvertTo-Json -Depth 20 } else { $spawnRaw }
            childSessionKey       = $childSessionKey
            subagent_uuid         = $subagentUuid
        }

        if ($resultPath) {
            Write-MconDiagnosticsJson -Path $resultPath -Data $errorResult | Out-Null
        }
        if ($payload.PSObject.Properties.Name -contains 'workspace_path' -and -not [string]::IsNullOrWhiteSpace([string]$payload.workspace_path)) {
            Write-MconAssignWorkflowState -WorkspacePath ([string]$payload.workspace_path) -State 'failed' -Fields @{
                task_id      = $errorResult.taskId
                job_id       = $errorResult.deferredSpawn.jobId
                phase        = $errorResult.phase
                reason       = $errorResult.error
                payload_path = $PayloadPath
                result_path  = $resultPath
            } | Out-Null
        }
        return $errorResult
    }
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

    $recoverySweep = @()
    try {
        $recoverySweep = @(Invoke-MconDeferredAssignRecoverySweep -WorkspacePath $workspacePath)
    } catch {
        Write-MconAssignWorkflowState -WorkspacePath $workspacePath -State 'recovery_failed' -Fields @{
            phase  = 'recovery_sweep'
            reason = $_.Exception.Message
        } | Out-Null
    }

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

    # The OpenClaw registry in openclaw.json is authoritative for worker spawn identity.
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
    $workerSessionAgentNames = @()
    foreach ($candidateAgentName in @($workerSpawnAgentId, $workerLegacyAgentName)) {
        if (-not [string]::IsNullOrWhiteSpace($candidateAgentName) -and ($workerSessionAgentNames -notcontains [string]$candidateAgentName)) {
            $workerSessionAgentNames += [string]$candidateAgentName
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

    $currentSubagentUuid = Get-MconTaskSubagentUuid -TaskData $task

    $currentStatus = $null
    if ($task.PSObject.Properties.Name -contains 'status' -and $task.status) {
        $currentStatus = ([string]$task.status).ToLowerInvariant()
    }

    $existingSubagentSession = $null
    if (-not [string]::IsNullOrWhiteSpace($currentSubagentUuid)) {
        $existingSubagentSession = Resolve-MconRegisteredSubagentSession -OpenClawRoot $openClawRoot -AgentName $workerSessionAgentNames -SubagentUuid $currentSubagentUuid -TaskId $TaskId
    }

    $taskAlreadyActiveForWorker = ($currentAssignedAgentId -eq $assignedAgentId) -and ($currentStatus -and $currentStatus -ne 'inbox')

    if (
        $taskAlreadyActiveForWorker -and
        (-not [string]::IsNullOrWhiteSpace($currentSubagentUuid)) -and
        $existingSubagentSession
    ) {
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
            spawn                = [ordered]@{
                status          = 'existing'
                childSessionKey = $existingSubagentSession.childSessionKey
                runId           = $null
                mode            = 'existing'
                subagent_uuid   = $currentSubagentUuid
            }
            finalTask            = Get-MconAssignTaskProjection -TaskData $task
        }
    }

    if ($taskAlreadyActiveForWorker -and -not [string]::IsNullOrWhiteSpace($currentSubagentUuid) -and -not $existingSubagentSession) {
        return [ordered]@{
            ok                    = $false
            phase                 = 'precondition'
            error                 = "Task is already assigned to worker $WorkerAgentId with subagent_uuid $currentSubagentUuid, but no matching registered OpenClaw session exists for any expected agent session id ($($workerSessionAgentNames -join ', ')). Refusing idempotent success on stale assignment state."
            taskId                = $TaskId
            boardId               = $boardId
            workerAgentId         = $WorkerAgentId
            workerSpawnAgentId    = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath            = $bundlePath
            workerTaskDataPath    = $workerTaskDataPath
            task                  = Get-MconAssignTaskProjection -TaskData $task
            spawn                 = [ordered]@{
                status          = 'missing'
                childSessionKey = $null
                runId           = $null
                mode            = 'existing'
                subagent_uuid   = $currentSubagentUuid
            }
        }
    }

    $workerTask = @"
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

    $spawnPrompt = @"
ASSIGNMENT_AUTHORIZED: true
This prompt was generated by mcon workflow assign as its internal subagent-creation step.
It is not a manual fallback and must preserve the lead task session as the requester.
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
        $gatewayConfig = Get-MconOpenClawGatewayConfig -WorkspacePath $workspacePath
        $gatewayUri = "http://127.0.0.1:$($gatewayConfig.port)/v1/chat/completions"
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
            async             = $true
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
                    step         = 'launch_deferred_spawn_worker'
                    type         = 'process_launch'
                    program      = 'pwsh'
                    arguments    = @(
                        '-NoProfile',
                        '-NoLogo',
                        '-NonInteractive',
                        '-File',
                        $resolvedMconScriptPath,
                        'workflow',
                        'assign',
                        '--process-deferred-spawn',
                        '--payload',
                        '<generated payload path>'
                    )
                    workingDirectory = $workspacePath
                },
                [ordered]@{
                    step      = 'deferred_subagent_spawn'
                    type      = 'gateway_chat'
                    mode      = 'background'
                    initialDelaySeconds = 2
                    retryDelaySeconds = 5
                    maxAttempts = 6
                    method    = 'POST'
                    uri       = $gatewayUri
                    headers   = @{
                        Authorization            = 'Bearer <gateway token>'
                        'x-openclaw-session-key' = $runtimeOriginSessionKey
                    }
                    body      = @{
                        model       = "openclaw/$LeadAgentId"
                        temperature = 0
                        messages    = @(
                            @{
                                role    = 'user'
                                content = $spawnPrompt
                            }
                        )
                    }
                    targetAgent = $LeadAgentId
                    sessionId   = $runtimeOriginSessionKey
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

    $spawnDispatch = [ordered]@{
        transport   = 'gateway_chat'
        targetAgent = $LeadAgentId
        sessionKey  = $runtimeOriginSessionKey
        model       = "openclaw/$LeadAgentId"
        timeoutSec  = 300
        deferred    = $true
    }

    $deferredPayload = [ordered]@{
        workspace_path            = $workspacePath
        openclaw_root             = $openClawRoot
        lead_agent_id             = $LeadAgentId
        runtime_origin_session_key = $runtimeOriginSessionKey
        spawn_prompt              = $spawnPrompt
        timeout_seconds           = 300
        initial_delay_seconds     = 2
        retry_delay_seconds       = 5
        max_attempts              = 6
        task_id                   = $TaskId
        board_id                  = $boardId
        task_uri                  = $taskUri
        auth_token                = $authToken
        assigned_agent_id         = $assignedAgentId
        worker_agent_id           = $WorkerAgentId
        worker_spawn_agent_id     = $workerSpawnAgentId
        worker_legacy_agent_name  = $workerLegacyAgentName
        bundle_path               = $bundlePath
        worker_task_data_path     = $workerTaskDataPath
    }

    try {
        $deferredSpawn = Start-MconDeferredAssignSpawn `
            -WorkspacePath $workspacePath `
            -MconScriptPath $resolvedMconScriptPath `
            -DiagnosticsDir $resolvedDiagnosticsDir `
            -TaskId $TaskId `
            -Payload $deferredPayload
    } catch {
        return [ordered]@{
            ok                    = $false
            phase                 = 'subagent_spawn_queue'
            error                 = "Failed to launch deferred spawn worker: $($_.Exception.Message)"
            taskId                = $TaskId
            workerAgentId         = $WorkerAgentId
            workerSpawnAgentId    = $workerSpawnAgentId
            workerLegacyAgentName = $workerLegacyAgentName
            bundlePath            = $bundlePath
            workerTaskDataPath    = $workerTaskDataPath
            spawnDispatch         = $spawnDispatch
        }
    }

        return [ordered]@{
            ok                    = $true
            mode                  = 'assign_deferred'
            async                 = $true
        taskId                = $TaskId
        boardId               = $boardId
        workerAgentId         = $WorkerAgentId
        workerSpawnAgentId    = $workerSpawnAgentId
        workerLegacyAgentName = $workerLegacyAgentName
        bundlePath            = $bundlePath
            workerTaskDataPath    = $workerTaskDataPath
            spawnDispatch         = $spawnDispatch
            deferredSpawn         = $deferredSpawn
            recoverySweep         = @($recoverySweep)
            nextStep              = 'A detached assign worker will sleep briefly, send the spawn prompt to the task session, retry on lock/transport failures, and patch the board after a real childSessionKey is returned.'
        }
}

Export-ModuleMember -Function Invoke-MconAssign, Invoke-MconDeferredAssignSpawn, ConvertTo-MconCanonicalAssignmentSessionKey, Get-MconTaskSubagentUuid, Get-MconAssignTaskProjection, Get-MconNormalizedWorkerAgentId, Resolve-MconRegisteredSubagentSession, Resolve-MconRegisteredSubagentSessionByTask, Get-MconAssignTaskBundlePaths, New-MconBootstrapBundle, Write-MconWorkerTaskData, Get-MconAssignmentOriginSessionKey
