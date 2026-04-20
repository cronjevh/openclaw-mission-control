#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mission Control board dispatch gate.

.DESCRIPTION
    Evaluates board state and emits a single JSON object describing whether the
    current agent should wake the LLM for this cycle.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BoardId,

    [Parameter(Mandatory)]
    [string]$AgentId,

    [ValidateSet('lead', 'worker', 'verifier')]
    [string]$AgentRole,

    [string]$WorkspacePath,

    [string]$BaseUrl = 'http://localhost:8002',

    [int]$ChatLimit = 20,

    [int]$HeartbeatEvery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Resolve-WorkspacePath {
    param(
        [string]$ProvidedWorkspacePath,
        [string]$AgentIdValue,
        [string]$BoardIdValue
    )

    if ($ProvidedWorkspacePath) {
        if (-not (Test-Path -LiteralPath $ProvidedWorkspacePath)) {
            throw "WorkspacePath does not exist: $ProvidedWorkspacePath"
        }

        return (Resolve-Path -LiteralPath $ProvidedWorkspacePath).Path
    }

    $candidatePaths = @(
        "/home/cronjev/.openclaw/workspace-mc-$AgentIdValue",
        "/home/cronjev/.openclaw/workspace-lead-$BoardIdValue"
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            return (Resolve-Path -LiteralPath $candidatePath).Path
        }
    }

    throw "Unable to resolve WorkspacePath. Pass -WorkspacePath or create a default workspace for agent $AgentIdValue or board $BoardIdValue."
}

function Read-AuthToken {
    param(
        [string]$WorkspacePathValue
    )

    $toolsPath = Join-Path $WorkspacePathValue 'TOOLS.md'
    if (-not (Test-Path -LiteralPath $toolsPath)) {
        throw "TOOLS.md not found at $toolsPath"
    }

    $toolsContent = Get-Content -LiteralPath $toolsPath -Raw
    if ($toolsContent -match '(?m)^\s*AUTH_TOKEN\s*=\s*([^\r\n]+?)\s*$') {
        return $matches[1].Trim().Trim('`', '"', "'")
    }

    throw "AUTH_TOKEN not found in $toolsPath"
}

function Invoke-BoardApi {
    param(
        [string]$Uri,
        [string]$AuthToken
    )

    $headers = @{
        'X-Agent-Token' = $AuthToken
    }

    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec 10 -ErrorAction Stop
    } catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            throw "auth failure calling $Uri"
        }

        if ($statusCode) {
            throw "API request failed for $Uri with HTTP ${statusCode}: $($_.Exception.Message)"
        }

        throw "API request failed for ${Uri}: $($_.Exception.Message)"
    }
}

function Get-ResponseItems {
    param(
        $Response
    )

    if ($null -eq $Response) {
        return @()
    }

    if ($Response.PSObject.Properties.Name -contains 'items') {
        return @($Response.items)
    }

    return @($Response)
}

function Get-ItemText {
    param(
        $Item
    )

    foreach ($propertyName in @('content', 'text', 'message', 'body')) {
        if ($Item.PSObject.Properties.Name -contains $propertyName) {
            $value = $Item.$propertyName
            if ($null -ne $value -and "$value".Trim()) {
                return "$value"
            }
        }
    }

    return ''
}

function Test-HasWork {
    param(
        [string]$Uri,
        [string]$AuthToken
    )

    $response = Invoke-BoardApi -Uri $Uri -AuthToken $AuthToken
    return (@(Get-ResponseItems -Response $response).Count -gt 0)
}

function Get-AgentRoleValue {
    param(
        [string]$ProvidedRole,
        [string]$WorkspacePathValue
    )

    if ($ProvidedRole) {
        return $ProvidedRole
    }

    $workspaceLeaf = Split-Path -Path $WorkspacePathValue -Leaf
    if ($workspaceLeaf -like 'workspace-lead-*') {
        return 'lead'
    }

    if ($workspaceLeaf -like 'workspace-mc-*') {
        $agentsPath = Join-Path $WorkspacePathValue 'AGENTS.md'
        if (Test-Path -LiteralPath $agentsPath) {
            $agentsContent = Get-Content -LiteralPath $agentsPath -Raw
            if ($agentsContent -match '(?im)^\s*this workspace is for verifier agent:') {
                return 'verifier'
            }
        }

        return 'worker'
    }

    return 'worker'
}

function New-Result {
    param(
        [bool]$Act,
        [string]$Reason,
        [string]$AgentRoleValue,
        [string]$BoardIdValue,
        [string]$AgentIdValue,
        [hashtable]$Summary,
        [array]$Tasks = @()
    )

    [ordered]@{
        act = $Act
        reason = $Reason
        agentRole = $AgentRoleValue
        boardId = $BoardIdValue
        agentId = $AgentIdValue
        summary = $Summary
        tasks = $Tasks
    }
}

function Get-InvocationAgentId {
    param(
        [string]$AgentIdValue,
        [string]$BoardIdValue,
        [string]$AgentRoleValue
    )

    if ($AgentRoleValue -eq 'lead') {
        return "lead-$BoardIdValue"
    }

    return "mc-$AgentIdValue"
}

function Get-TaskDirectoryPath {
    param(
        [string]$WorkspacePath,
        [string]$TaskId
    )

    return (Join-Path (Join-Path $WorkspacePath 'tasks') $TaskId)
}

function Get-LeadWorkspacePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BoardId
    )

    return "/home/cronjev/.openclaw/workspace-lead-$BoardId"
}

function Invoke-LeadRosterApi {
    param(
        [string]$BaseUri,
        [string]$BoardId,
        [string]$AuthToken
    )

    $encodedBoardId = [uri]::EscapeDataString($BoardId)
    $uri = "$BaseUri/api/v1/agent/agents?board_id=$encodedBoardId&limit=100"
    return Invoke-BoardApi -Uri $uri -AuthToken $AuthToken
}

function Get-CommentsProjection {
    param(
        $Comments = $null
    )

    $items = @()
    foreach ($comment in @($Comments | Where-Object { $null -ne $_ })) {
        $items += [ordered]@{
            id = $comment.id
            created_at = $comment.created_at
            author_name = if ($comment.PSObject.Properties.Name -contains 'author_name') { $comment.author_name } else { $null }
            agent_id = if ($comment.PSObject.Properties.Name -contains 'agent_id') { $comment.agent_id } else { $null }
            agent_name = if ($comment.PSObject.Properties.Name -contains 'agent_name') { $comment.agent_name } else { $null }
            message = if ($comment.PSObject.Properties.Name -contains 'message') { $comment.message } else { $null }
        }
    }

    return @(
        $items | Sort-Object -Property @{
            Expression = {
                if ($_.created_at) { [datetimeoffset]$_.created_at } else { [datetimeoffset]::MinValue }
            }
            Descending = $false
        }
    )
}

function ConvertTo-WorkerAgentContext {
    param(
        $Agent
    )

    if ($null -eq $Agent) {
        return $null
    }

    $identity = $null
    if ($Agent.PSObject.Properties.Name -contains 'identity_profile') {
        $identity = $Agent.identity_profile
    }

    $roleDescription = $null
    $communicationStyle = $null
    $modelPreference = $null
    if ($identity) {
        if ($identity.PSObject.Properties.Name -contains 'role') {
            $roleDescription = $identity.role
        }
        if ($identity.PSObject.Properties.Name -contains 'communication_style') {
            $communicationStyle = $identity.communication_style
        }
        if ($identity.PSObject.Properties.Name -contains 'model_preference') {
            $modelPreference = $identity.model_preference
        }
    }

    [ordered]@{
        id = $Agent.id
        name = $Agent.name
        status = $Agent.status
        board_id = $Agent.board_id
        workspace_dir = "/home/cronjev/.openclaw/workspace-mc-$($Agent.id)"
        roleDescription = $roleDescription
        communicationStyle = $communicationStyle
        modelPreference = $modelPreference
        identity_profile = $identity
        identity_template = if ($Agent.PSObject.Properties.Name -contains 'identity_template') { $Agent.identity_template } else { $null }
        soul_template = if ($Agent.PSObject.Properties.Name -contains 'soul_template') { $Agent.soul_template } else { $null }
        openclaw_session_id = if ($Agent.PSObject.Properties.Name -contains 'openclaw_session_id') { $Agent.openclaw_session_id } else { $null }
        is_board_lead = if ($Agent.PSObject.Properties.Name -contains 'is_board_lead') { [bool]$Agent.is_board_lead } else { $false }
        is_gateway_main = if ($Agent.PSObject.Properties.Name -contains 'is_gateway_main') { [bool]$Agent.is_gateway_main } else { $false }
        last_seen_at = if ($Agent.PSObject.Properties.Name -contains 'last_seen_at') { $Agent.last_seen_at } else { $null }
        created_at = if ($Agent.PSObject.Properties.Name -contains 'created_at') { $Agent.created_at } else { $null }
        updated_at = if ($Agent.PSObject.Properties.Name -contains 'updated_at') { $Agent.updated_at } else { $null }
    }
}

function Write-TaskContextBundle {
    param(
        [string]$WorkspacePath,
        [string]$BoardId,
        [string]$LeadAgentId,
        [string]$InvocationAgentId,
        [string]$BaseUri,
        [string]$AuthToken,
        $TaskSummary,
        [string]$TaskBundleWorkspacePath
    )

    if (-not $TaskSummary -or -not $TaskSummary.id) {
        return $null
    }

    $taskContextDir = Get-TaskDirectoryPath -WorkspacePath $WorkspacePath -TaskId $TaskSummary.id
    if (-not (Test-Path -LiteralPath $taskContextDir)) {
        New-Item -ItemType Directory -Path $taskContextDir -Force | Out-Null
    }

    if (-not $TaskBundleWorkspacePath) {
        $TaskBundleWorkspacePath = $WorkspacePath
    }

    $taskDir = Get-TaskDirectoryPath -WorkspacePath $TaskBundleWorkspacePath -TaskId $TaskSummary.id
    $taskDeliverablesDir = Join-Path $taskDir 'deliverables'
    $taskEvidenceDir = Join-Path $taskDir 'evidence'
    foreach ($dir in @($taskDir, $taskDeliverablesDir, $taskEvidenceDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $taskUri = "$BaseUri/api/v1/agent/boards/$([uri]::EscapeDataString($BoardId))/tasks/$([uri]::EscapeDataString($TaskSummary.id))"
    $taskDetail = Invoke-BoardApi -Uri $taskUri -AuthToken $AuthToken
    $commentsUri = "$BaseUri/api/v1/agent/boards/$([uri]::EscapeDataString($BoardId))/tasks/$([uri]::EscapeDataString($TaskSummary.id))/comments?limit=200"
    $commentsResponse = Invoke-BoardApi -Uri $commentsUri -AuthToken $AuthToken
    $taskComments = Get-CommentsProjection -Comments (Get-ResponseItems -Response $commentsResponse)

    $rosterResponse = Invoke-LeadRosterApi -BaseUri $BaseUri -BoardId $BoardId -AuthToken $AuthToken
    $workerAgents = @(
        Get-ResponseItems -Response $rosterResponse |
            Where-Object { $_ -and -not $_.is_board_lead } |
            ForEach-Object { ConvertTo-WorkerAgentContext -Agent $_ }
    )

    $taskDataPath = Join-Path $taskContextDir 'taskData.json'
    $taskData = [ordered]@{
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        board_id = $BoardId
        lead_agent_id = $LeadAgentId
        invocation_agent_id = $InvocationAgentId
        task_directory = $taskDir
        deliverables_directory = $taskDeliverablesDir
        evidence_directory = $taskEvidenceDir
        task = $taskDetail
        comments = $taskComments
        boardWorkers = $workerAgents
    }

    $taskData | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $taskDataPath -Encoding UTF8
    return [pscustomobject]@{
        task_data_path = $taskDataPath
        task_directory = $taskDir
        deliverables_directory = $taskDeliverablesDir
        evidence_directory = $taskEvidenceDir
    }
}

function Get-TaskSubagentUuid {
    param(
        $Task,
        [string]$AuthToken,
        [string]$BaseUri,
        [string]$BoardId,
        [string]$AgentId
    )

    # Try to get subagent_uuid from task custom fields first
    if ($Task.PSObject.Properties.Name -contains 'custom_field_values') {
        $cf = $Task.custom_field_values
        if ($cf -and $cf.PSObject.Properties.Name -contains 'subagent_uuid' -and $cf.subagent_uuid) {
            return $cf.subagent_uuid
        }
    }

    # Fallback: look for subagent_uuid in task fields
    if ($Task.PSObject.Properties.Name -contains 'subagent_uuid') {
        return $Task.subagent_uuid
    }

    return $null
}

function Get-IsTaskBacklog {
    param(
        $Task
    )

    if ($null -eq $Task) {
        return $false
    }

    $isBacklog = $false
    if ($Task.PSObject.Properties.Name -contains 'custom_field_values') {
        $cf = $Task.custom_field_values
        if ($cf -and $cf.PSObject.Properties.Name -contains 'backlog' -and $cf.backlog) {
            $isBacklog = $cf.backlog
        }
    }
    if ($Task.PSObject.Properties.Name -contains 'backlog' -and $Task.backlog) {
        $isBacklog = $Task.backlog
    }

    return [bool]$isBacklog
}

function Get-BoardVerifierAgents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUri,
        [Parameter(Mandatory = $true)]
        [string]$BoardId,
        [Parameter(Mandatory = $true)]
        [string]$AuthToken
    )

    $rosterResponse = Invoke-LeadRosterApi -BaseUri $BaseUri -BoardId $BoardId -AuthToken $AuthToken
    $agents = @(Get-ResponseItems -Response $rosterResponse)

    return @(
        $agents | Where-Object {
            if ($null -eq $_ -or $_.is_board_lead -or $_.is_gateway_main) {
                return $false
            }

            $role = $null
            if ($_.identity_profile -and $_.identity_profile.PSObject.Properties.Name -contains 'role') {
                $role = [string]$_.identity_profile.role
            } elseif ($_.PSObject.Properties.Name -contains 'role') {
                $role = [string]$_.role
            }

            return $role -and $role.Trim().Equals('verifier', [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
}

try {
    $resolvedWorkspacePath = Resolve-WorkspacePath -ProvidedWorkspacePath $WorkspacePath -AgentIdValue $AgentId -BoardIdValue $BoardId
    $authToken = Read-AuthToken -WorkspacePathValue $resolvedWorkspacePath
    $resolvedAgentRole = Get-AgentRoleValue -ProvidedRole $AgentRole -WorkspacePathValue $resolvedWorkspacePath
    $invocationAgentId = Get-InvocationAgentId -AgentIdValue $AgentId -BoardIdValue $BoardId -AgentRoleValue $resolvedAgentRole

    $summary = [ordered]@{
        paused = $false
        inbox = $false
        assignedInbox = $false
        assignedInProgress = $false
        review = $false
    }

    $baseUri = $BaseUrl.TrimEnd('/')
    $encodedBoardId = [uri]::EscapeDataString($BoardId)
    $encodedAgentId = [uri]::EscapeDataString($AgentId)

    $memoryUri = "$baseUri/api/v1/agent/boards/$encodedBoardId/memory?is_chat=true&limit=$ChatLimit"
    $memoryResponse = Invoke-BoardApi -Uri $memoryUri -AuthToken $authToken
    $memoryItems = Get-ResponseItems -Response $memoryResponse

    $paused = $false
    foreach ($item in $memoryItems) {
        $text = (Get-ItemText -Item $item).Trim()
        if ($text -eq '/pause') {
            $paused = $true
            break
        }

        if ($text -eq '/resume') {
            $paused = $false
            break
        }
    }

    $summary.paused = $paused

    if ($paused) {
        $result = New-Result -Act $false -Reason 'paused' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary
        $result | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }

    switch ($resolvedAgentRole) {
        'lead' {
            $reviewUri = "$baseUri/api/v1/agent/boards/$encodedBoardId/tasks?status=review"
            $inboxUri = "$baseUri/api/v1/agent/boards/$encodedBoardId/tasks?status=inbox"

            $reviewResponse = Invoke-BoardApi -Uri $reviewUri -AuthToken $authToken
            $inboxResponse = Invoke-BoardApi -Uri $inboxUri -AuthToken $authToken

            $reviewTasks = Get-ResponseItems -Response $reviewResponse
            $inboxTasks = Get-ResponseItems -Response $inboxResponse

            if ($inboxTasks) {
                $inboxTasks = @($inboxTasks | Where-Object { -not (Get-IsTaskBacklog -Task $_) })
            }

            $inboxCount = if ($inboxTasks) { $inboxTasks.Count } else { 0 }

            $summary.review = (@($reviewTasks).Count -gt 0)
            $summary.inbox = ($inboxCount -gt 0)

            $allTasks = @()
            if ($summary.review) {
                $verifierAgents = @(Get-BoardVerifierAgents -BaseUri $baseUri -BoardId $BoardId -AuthToken $authToken)
                if ($verifierAgents.Count -eq 0) {
                    $result = New-Result -Act $false -Reason 'review_tasks_no_verifier' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary
                    $result | ConvertTo-Json -Depth 6 -Compress
                    exit 0
                }
            }

            if ($summary.inbox) {
                foreach ($task in $inboxTasks) {
                    $taskContext = Write-TaskContextBundle -WorkspacePath $resolvedWorkspacePath -BoardId $BoardId -LeadAgentId $AgentId -InvocationAgentId $invocationAgentId -BaseUri $baseUri -AuthToken $authToken -TaskSummary $task
                    $allTasks += @{
                        id = $task.id
                        status = 'inbox'
                        title = $task.title
                        subagent_uuid = (Get-TaskSubagentUuid -Task $task -AuthToken $authToken -BaseUri $baseUri -BoardId $BoardId -AgentId $AgentId)
                        task_data_path = $taskContext.task_data_path
                        task_directory = $taskContext.task_directory
                        deliverables_directory = $taskContext.deliverables_directory
                        evidence_directory = $taskContext.evidence_directory
                    }
                }
            }

            if ($summary.inbox) {
                $reason = 'lead_inbox'
                $result = New-Result -Act $true -Reason $reason -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary -Tasks $allTasks
                $result | ConvertTo-Json -Depth 6 -Compress
                exit 0
            }

            $result = New-Result -Act $false -Reason 'idle' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary
            $result | ConvertTo-Json -Depth 6 -Compress
            exit 0
        }

        'verifier' {
            $reviewUri = "$baseUri/api/v1/agent/boards/$encodedBoardId/tasks?status=review"
            $reviewResponse = Invoke-BoardApi -Uri $reviewUri -AuthToken $authToken
            $reviewTasks = @(Get-ResponseItems -Response $reviewResponse)

            $summary.review = ($reviewTasks.Count -gt 0)
            if (-not $summary.review) {
                $result = New-Result -Act $false -Reason 'idle' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary
                $result | ConvertTo-Json -Depth 6 -Compress
                exit 0
            }

            $leadWorkspacePath = Get-LeadWorkspacePath -BoardId $BoardId
            $allTasks = @()
            foreach ($task in $reviewTasks) {
                $taskContext = Write-TaskContextBundle `
                    -WorkspacePath $resolvedWorkspacePath `
                    -BoardId $BoardId `
                    -LeadAgentId $BoardId `
                    -InvocationAgentId $invocationAgentId `
                    -BaseUri $baseUri `
                    -AuthToken $authToken `
                    -TaskSummary $task `
                    -TaskBundleWorkspacePath $leadWorkspacePath
                $allTasks += @{
                    id = $task.id
                    status = 'review'
                    title = $task.title
                    subagent_uuid = (Get-TaskSubagentUuid -Task $task -AuthToken $authToken -BaseUri $baseUri -BoardId $BoardId -AgentId $AgentId)
                    task_data_path = $taskContext.task_data_path
                    task_directory = $taskContext.task_directory
                    deliverables_directory = $taskContext.deliverables_directory
                    evidence_directory = $taskContext.evidence_directory
                }
            }

            $result = New-Result -Act $true -Reason 'verifier_review' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary -Tasks $allTasks
            $result | ConvertTo-Json -Depth 6 -Compress
            exit 0
        }

        'worker' {
            $assignedInboxUri = "$baseUri/api/v1/agent/boards/$encodedBoardId/tasks?status=inbox&assigned_agent_id=$encodedAgentId"
            $assignedInProgressUri = "$baseUri/api/v1/agent/boards/$encodedBoardId/tasks?status=in_progress&assigned_agent_id=$encodedAgentId"

            $assignedInboxResponse = Invoke-BoardApi -Uri $assignedInboxUri -AuthToken $authToken
            $assignedInProgressResponse = Invoke-BoardApi -Uri $assignedInProgressUri -AuthToken $authToken

            $assignedInboxTasks = Get-ResponseItems -Response $assignedInboxResponse
            $assignedInProgressTasks = Get-ResponseItems -Response $assignedInProgressResponse

            # Filter out backlog=true tasks for worker role
            if ($assignedInboxTasks) {
                $assignedInboxTasks = @($assignedInboxTasks | Where-Object { 
                    # Check backlog flag in custom fields or direct property
                    $isBacklog = $false
                    if ($_.PSObject.Properties.Name -contains 'custom_field_values') {
                        $cf = $_.custom_field_values
                        if ($cf -and $cf.backlog) { $isBacklog = $cf.backlog }
                    }
                    if ($_.PSObject.Properties.Name -contains 'backlog') {
                        $isBacklog = $_.backlog
                    }
                    -not $isBacklog
                })
            }

            if ($assignedInProgressTasks) {
                $assignedInProgressTasks = @($assignedInProgressTasks | Where-Object {
                    $isBacklog = $false
                    if ($_.PSObject.Properties.Name -contains 'custom_field_values') {
                        $cf = $_.custom_field_values
                        if ($cf -and $cf.backlog) { $isBacklog = $cf.backlog }
                    }
                    if ($_.PSObject.Properties.Name -contains 'backlog') {
                        $isBacklog = $_.backlog
                    }
                    -not $isBacklog
                })
            }

            $assignedInboxCount = if ($assignedInboxTasks) { $assignedInboxTasks.Count } else { 0 }
            $assignedInProgressCount = if ($assignedInProgressTasks) { $assignedInProgressTasks.Count } else { 0 }

            $summary.assignedInbox = ($assignedInboxCount -gt 0)
            $summary.assignedInProgress = ($assignedInProgressCount -gt 0)

            $allTasks = @()
            if ($summary.assignedInbox) {
                foreach ($task in $assignedInboxTasks) {
                    $taskContext = Write-TaskContextBundle -WorkspacePath $resolvedWorkspacePath -BoardId $BoardId -LeadAgentId $BoardId -InvocationAgentId $invocationAgentId -BaseUri $baseUri -AuthToken $authToken -TaskSummary $task
                    $allTasks += @{
                        id = $task.id
                        status = 'inbox'
                        title = $task.title
                        subagent_uuid = (Get-TaskSubagentUuid -Task $task -AuthToken $authToken -BaseUri $baseUri -BoardId $BoardId -AgentId $AgentId)
                        task_data_path = $taskContext.task_data_path
                        task_directory = $taskContext.task_directory
                        deliverables_directory = $taskContext.deliverables_directory
                        evidence_directory = $taskContext.evidence_directory
                    }
                }
                $result = New-Result -Act $true -Reason 'worker_inbox' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary -Tasks $allTasks
                $result | ConvertTo-Json -Depth 6 -Compress
                exit 0
            }

            if ($summary.assignedInProgress) {
                foreach ($task in $assignedInProgressTasks) {
                    $taskContext = Write-TaskContextBundle -WorkspacePath $resolvedWorkspacePath -BoardId $BoardId -LeadAgentId $BoardId -InvocationAgentId $invocationAgentId -BaseUri $baseUri -AuthToken $authToken -TaskSummary $task
                    $allTasks += @{
                        id = $task.id
                        status = 'in_progress'
                        title = $task.title
                        subagent_uuid = (Get-TaskSubagentUuid -Task $task -AuthToken $authToken -BaseUri $baseUri -BoardId $BoardId -AgentId $AgentId)
                        task_data_path = $taskContext.task_data_path
                        task_directory = $taskContext.task_directory
                        deliverables_directory = $taskContext.deliverables_directory
                        evidence_directory = $taskContext.evidence_directory
                    }
                }
                $result = New-Result -Act $true -Reason 'worker_in_progress' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary -Tasks $allTasks
                $result | ConvertTo-Json -Depth 6 -Compress
                exit 0
            }

            $result = New-Result -Act $false -Reason 'idle' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary
            $result | ConvertTo-Json -Depth 6 -Compress
            exit 0
        }

        default {
            throw "Unsupported agent role: $resolvedAgentRole"
        }
    }
} catch {
    $hasException = $_.PSObject.Properties.Name -contains 'Exception'
    $apiDown = $false
    $errMsg = ""

    if ($hasException -and $_.Exception) {
        $ex = $_.Exception
        # Detect connection/refused/timeouts
        $msg = $ex.Message
        if ($msg -match 'connect(ion)? refused' -or $msg -match 'No connection could be made' -or $msg -match 'timed out' -or $msg -match 'Failed to connect' -or $msg -match 'Unable to connect' -or $msg -match 'actively refused') {
            $apiDown = $true
        } elseif ($ex.PSObject.Properties.Name -contains 'InnerException' -and $ex.InnerException) {
            $innerMsg = $ex.InnerException.Message
            if ($innerMsg -match 'connect(ion)? refused' -or $innerMsg -match 'No connection could be made' -or $innerMsg -match 'timed out' -or $innerMsg -match 'Failed to connect' -or $innerMsg -match 'Unable to connect' -or $innerMsg -match 'actively refused') {
                $apiDown = $true
            }
        }
    }

    if ($apiDown) {
        $errMsg = "[ERROR] The API backend is not responding or is down. Please check that the API service is running and accessible."
    } else {
        $detail = ($_ | Out-String).Trim()
        $errMsg = "[ERROR] Unexpected error occurred: $detail"
    }

    Write-Error $errMsg
    exit 1
}
