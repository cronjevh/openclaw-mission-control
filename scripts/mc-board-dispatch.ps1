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

    [ValidateSet('lead', 'worker')]
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
        if ($cf -and $cf.subagent_uuid) {
            return $cf.subagent_uuid
        }
    }

    # Fallback: look for subagent_uuid in task fields
    if ($Task.PSObject.Properties.Name -contains 'subagent_uuid') {
        return $Task.subagent_uuid
    }

    return $null
}

try {
    $resolvedWorkspacePath = Resolve-WorkspacePath -ProvidedWorkspacePath $WorkspacePath -AgentIdValue $AgentId -BoardIdValue $BoardId
    $authToken = Read-AuthToken -WorkspacePathValue $resolvedWorkspacePath
    $resolvedAgentRole = Get-AgentRoleValue -ProvidedRole $AgentRole -WorkspacePathValue $resolvedWorkspacePath

    $summary = [ordered]@{
        paused = $false
        inbox = $false
        review = $false
        assignedInbox = $false
        assignedInProgress = $false
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
            $inboxUri = "$baseUri/api/v1/agent/boards/$encodedBoardId/tasks?status=inbox"
            $reviewUri = "$baseUri/api/v1/agent/boards/$encodedBoardId/tasks?status=review"

            $inboxResponse = Invoke-BoardApi -Uri $inboxUri -AuthToken $authToken
            $reviewResponse = Invoke-BoardApi -Uri $reviewUri -AuthToken $authToken

            $inboxTasks = Get-ResponseItems -Response $inboxResponse
            $reviewTasks = Get-ResponseItems -Response $reviewResponse

            $inboxCount = if ($inboxTasks) { $inboxTasks.Count } else { 0 }
            $reviewCount = if ($reviewTasks) { $reviewTasks.Count } else { 0 }

            $summary.inbox = ($inboxCount -gt 0)
            $summary.review = ($reviewCount -gt 0)

            $allTasks = @()
            if ($summary.inbox) {
                foreach ($task in $inboxTasks) {
                    $allTasks += @{
                        id = $task.id
                        status = 'inbox'
                        title = $task.title
                        subagent_uuid = (Get-TaskSubagentUuid -Task $task -AuthToken $authToken -BaseUri $baseUri -BoardId $BoardId -AgentId $AgentId)
                    }
                }
                $result = New-Result -Act $true -Reason 'lead_inbox' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary -Tasks $allTasks
                $result | ConvertTo-Json -Depth 6 -Compress
                exit 0
            }

            if ($summary.review) {
                foreach ($task in $reviewTasks) {
                    $allTasks += @{
                        id = $task.id
                        status = 'review'
                        title = $task.title
                        subagent_uuid = (Get-TaskSubagentUuid -Task $task -AuthToken $authToken -BaseUri $baseUri -BoardId $BoardId -AgentId $AgentId)
                    }
                }
                $result = New-Result -Act $true -Reason 'lead_review' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary -Tasks $allTasks
                $result | ConvertTo-Json -Depth 6 -Compress
                exit 0
            }

            $result = New-Result -Act $false -Reason 'idle' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary
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
                    $allTasks += @{
                        id = $task.id
                        status = 'inbox'
                        title = $task.title
                        subagent_uuid = (Get-TaskSubagentUuid -Task $task -AuthToken $authToken -BaseUri $baseUri -BoardId $BoardId -AgentId $AgentId)
                    }
                }
                $result = New-Result -Act $true -Reason 'worker_inbox' -AgentRoleValue $resolvedAgentRole -BoardIdValue $BoardId -AgentIdValue $AgentId -Summary $summary -Tasks $allTasks
                $result | ConvertTo-Json -Depth 6 -Compress
                exit 0
            }

            if ($summary.assignedInProgress) {
                foreach ($task in $assignedInProgressTasks) {
                    $allTasks += @{
                        id = $task.id
                        status = 'in_progress'
                        title = $task.title
                        subagent_uuid = (Get-TaskSubagentUuid -Task $task -AuthToken $authToken -BaseUri $baseUri -BoardId $BoardId -AgentId $AgentId)
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
        # Suppress all other errors for LLM troubleshooting clarity
        $errMsg = "[ERROR] Unexpected error occurred. Please check API backend availability first."
    }

    Write-Error $errMsg
    exit 1
}
