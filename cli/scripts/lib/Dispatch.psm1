function Get-MconResponseItems {
    param($Response)

    if ($null -eq $Response) { return @() }
    if ($Response.PSObject.Properties.Name -contains 'items') { return @($Response.items) }
    return @($Response)
}

function Get-MconItemText {
    param($Item)

    foreach ($prop in @('content', 'text', 'message', 'body')) {
        if ($Item.PSObject.Properties.Name -contains $prop) {
            $value = $Item.$prop
            if ($null -ne $value -and "$value".Trim()) { return "$value" }
        }
    }
    return ''
}

function Test-MconTaskBacklog {
    param($Task)

    if ($null -eq $Task) { return $false }

    if ($Task.PSObject.Properties.Name -contains 'custom_field_values') {
        $cf = $Task.custom_field_values
        if ($cf -and $cf.PSObject.Properties.Name -contains 'backlog' -and $cf.backlog) {
            return [bool]$cf.backlog
        }
    }
    if ($Task.PSObject.Properties.Name -contains 'backlog' -and $Task.backlog) {
        return [bool]$Task.backlog
    }
    return $false
}

function Get-MconTaskSubagentUuid {
    param($Task)

    if ($Task.PSObject.Properties.Name -contains 'custom_field_values') {
        $cf = $Task.custom_field_values
        if ($cf -and $cf.PSObject.Properties.Name -contains 'subagent_uuid' -and $cf.subagent_uuid) { return $cf.subagent_uuid }
    }
    if ($Task.PSObject.Properties.Name -contains 'subagent_uuid') {
        return $Task.subagent_uuid
    }
    return $null
}

function Get-MconLeadWorkspacePath {
    param(
        [Parameter(Mandatory)][string]$BoardId
    )

    return "/home/cronjev/.openclaw/workspace-lead-$BoardId"
}

function Get-MconCommentsProjection {
    param($Comments = $null)

    $items = @()
    foreach ($comment in @($Comments | Where-Object { $null -ne $_ })) {
        $items += [ordered]@{
            id         = $comment.id
            created_at = $comment.created_at
            author_name = if ($comment.PSObject.Properties.Name -contains 'author_name') { $comment.author_name } else { $null }
            agent_id   = if ($comment.PSObject.Properties.Name -contains 'agent_id') { $comment.agent_id } else { $null }
            agent_name = if ($comment.PSObject.Properties.Name -contains 'agent_name') { $comment.agent_name } else { $null }
            message    = if ($comment.PSObject.Properties.Name -contains 'message') { $comment.message } else { $null }
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

function ConvertTo-MconWorkerAgentContext {
    param($Agent)

    if ($null -eq $Agent) { return $null }

    $identity = $null
    if ($Agent.PSObject.Properties.Name -contains 'identity_profile') {
        $identity = $Agent.identity_profile
    }

    $roleDescription = $null
    $communicationStyle = $null
    $modelPreference = $null
    if ($identity) {
        if ($identity.PSObject.Properties.Name -contains 'role') { $roleDescription = $identity.role }
        if ($identity.PSObject.Properties.Name -contains 'communication_style') { $communicationStyle = $identity.communication_style }
        if ($identity.PSObject.Properties.Name -contains 'model_preference') { $modelPreference = $identity.model_preference }
    }

    [ordered]@{
        id                 = $Agent.id
        name               = $Agent.name
        status             = $Agent.status
        board_id           = $Agent.board_id
        workspace_dir      = "/home/cronjev/.openclaw/workspace-mc-$($Agent.id)"
        roleDescription    = $roleDescription
        communicationStyle = $communicationStyle
        modelPreference    = $modelPreference
        identity_profile   = $identity
        identity_template  = if ($Agent.PSObject.Properties.Name -contains 'identity_template') { $Agent.identity_template } else { $null }
        soul_template      = if ($Agent.PSObject.Properties.Name -contains 'soul_template') { $Agent.soul_template } else { $null }
        openclaw_session_id = if ($Agent.PSObject.Properties.Name -contains 'openclaw_session_id') { $Agent.openclaw_session_id } else { $null }
        is_board_lead      = if ($Agent.PSObject.Properties.Name -contains 'is_board_lead') { [bool]$Agent.is_board_lead } else { $false }
        is_gateway_main    = if ($Agent.PSObject.Properties.Name -contains 'is_gateway_main') { [bool]$Agent.is_gateway_main } else { $false }
        last_seen_at       = if ($Agent.PSObject.Properties.Name -contains 'last_seen_at') { $Agent.last_seen_at } else { $null }
        created_at         = if ($Agent.PSObject.Properties.Name -contains 'created_at') { $Agent.created_at } else { $null }
        updated_at         = if ($Agent.PSObject.Properties.Name -contains 'updated_at') { $Agent.updated_at } else { $null }
    }
}

function Write-MconTaskContextBundle {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$LeadAgentId,
        [Parameter(Mandatory)][string]$InvocationAgentId,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)]$TaskSummary,
        [string]$TaskBundleWorkspacePath
    )

    if (-not $TaskSummary -or -not $TaskSummary.id) { return $null }

    $taskContextDir = Join-Path (Join-Path $WorkspacePath 'tasks') $TaskSummary.id
    if (-not (Test-Path -LiteralPath $taskContextDir)) {
        New-Item -ItemType Directory -Path $taskContextDir -Force | Out-Null
    }

    if (-not $TaskBundleWorkspacePath) {
        $TaskBundleWorkspacePath = $WorkspacePath
    }

    $taskDir = Join-Path (Join-Path $TaskBundleWorkspacePath 'tasks') $TaskSummary.id
    $taskDeliverablesDir = Join-Path $taskDir 'deliverables'
    $taskEvidenceDir = Join-Path $taskDir 'evidence'
    foreach ($dir in @($taskDir, $taskDeliverablesDir, $taskEvidenceDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $encodedBoardId = [uri]::EscapeDataString($BoardId)
    $encodedTaskId = [uri]::EscapeDataString($TaskSummary.id)

    $taskUri = "$BaseUrl/api/v1/agent/boards/$encodedBoardId/tasks/$encodedTaskId"
    $taskDetail = Invoke-MconApi -Method Get -Uri $taskUri -Token $AuthToken

    $commentsUri = "$BaseUrl/api/v1/agent/boards/$encodedBoardId/tasks/$encodedTaskId/comments?limit=200"
    $commentsResponse = Invoke-MconApi -Method Get -Uri $commentsUri -Token $AuthToken
    $taskComments = Get-MconCommentsProjection -Comments (Get-MconResponseItems -Response $commentsResponse)

    $rosterUri = "$BaseUrl/api/v1/agent/agents?board_id=$encodedBoardId&limit=100"
    $rosterResponse = Invoke-MconApi -Method Get -Uri $rosterUri -Token $AuthToken
    $workerAgents = @(
        Get-MconResponseItems -Response $rosterResponse |
            Where-Object { $_ -and -not $_.is_board_lead } |
            ForEach-Object { ConvertTo-MconWorkerAgentContext -Agent $_ }
    )

    $taskDataPath = Join-Path $taskContextDir 'taskData.json'
    $taskData = [ordered]@{
        generated_at          = (Get-Date).ToUniversalTime().ToString('o')
        board_id              = $BoardId
        lead_agent_id         = $LeadAgentId
        invocation_agent_id   = $InvocationAgentId
        task_directory        = $taskDir
        deliverables_directory = $taskDeliverablesDir
        evidence_directory    = $taskEvidenceDir
        task                  = $taskDetail
        comments              = $taskComments
        boardWorkers          = $workerAgents
    }

    $taskData | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $taskDataPath -Encoding UTF8
    return [ordered]@{
        task_data_path = $taskDataPath
        task_directory = $taskDir
        deliverables_directory = $taskDeliverablesDir
        evidence_directory = $taskEvidenceDir
    }
}

function New-MconDispatchResult {
    param(
        [bool]$Act,
        [string]$Reason,
        [string]$AgentRole,
        [string]$BoardId,
        [string]$AgentId,
        [hashtable]$Summary,
        [array]$Tasks = @()
    )

    [ordered]@{
        act       = $Act
        reason    = $Reason
        agentRole = $AgentRole
        boardId   = $BoardId
        agentId   = $AgentId
        summary   = $Summary
        tasks     = $Tasks
    }
}

function Get-MconBoardVerifierAgents {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId
    )

    $encodedBoardId = [uri]::EscapeDataString($BoardId)
    $rosterUri = "$BaseUrl/api/v1/agent/agents?board_id=$encodedBoardId&limit=100"
    $rosterResponse = Invoke-MconApi -Method Get -Uri $rosterUri -Token $Token
    $agents = @(Get-MconResponseItems -Response $rosterResponse)

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

function Invoke-MconDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$ChatLimit = 20
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id
    $agentId = $Config.agent_id
    $workspacePath = $Config.workspace_path

    $role = Resolve-MconExecutionRole -Wsp $Config.wsp -WorkspacePath $workspacePath

    $invocationAgentId = if ($role -eq 'lead') { "lead-$boardId" } else { "mc-$agentId" }

    $encodedBoardId = [uri]::EscapeDataString($boardId)
    $encodedAgentId = [uri]::EscapeDataString($agentId)

    $summary = [ordered]@{
        paused             = $false
        inbox              = $false
        assignedInbox      = $false
        assignedInProgress = $false
        review             = $false
    }

    $memoryUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/memory?is_chat=true&limit=$ChatLimit"
    $memoryResponse = Invoke-MconApi -Method Get -Uri $memoryUri -Token $authToken
    $memoryItems = Get-MconResponseItems -Response $memoryResponse

    $paused = $false
    foreach ($item in $memoryItems) {
        $text = (Get-MconItemText -Item $item).Trim()
        if ($text -eq '/pause') { $paused = $true; break }
        if ($text -eq '/resume') { $paused = $false; break }
    }

    $summary.paused = $paused

    if ($paused) {
        return New-MconDispatchResult -Act $false -Reason 'paused' -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary
    }

    switch ($role) {
        'lead' {
            $reviewUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/tasks?status=review"
            $inboxUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/tasks?status=inbox"

            $reviewResponse = Invoke-MconApi -Method Get -Uri $reviewUri -Token $authToken
            $inboxResponse = Invoke-MconApi -Method Get -Uri $inboxUri -Token $authToken

            $reviewTasks = @(Get-MconResponseItems -Response $reviewResponse)
            $inboxTasks = @(Get-MconResponseItems -Response $inboxResponse | Where-Object { -not (Test-MconTaskBacklog -Task $_) })

            $inboxCount = $inboxTasks.Count

            $summary.review = ($reviewTasks.Count -gt 0)
            $summary.inbox = ($inboxCount -gt 0)

            if ($summary.review) {
                $verifierAgents = @(Get-MconBoardVerifierAgents -BaseUrl $baseUrl -Token $authToken -BoardId $boardId)
                if ($verifierAgents.Count -eq 0) {
                    return New-MconDispatchResult -Act $false -Reason 'review_tasks_no_verifier' -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary
                }
            }

            $allTasks = @()
            if ($summary.inbox) {
                foreach ($task in $inboxTasks) {
                    $taskContext = Write-MconTaskContextBundle -WorkspacePath $workspacePath -BoardId $boardId -LeadAgentId $agentId -InvocationAgentId $invocationAgentId -BaseUrl $baseUrl -AuthToken $authToken -TaskSummary $task
                    $allTasks += [ordered]@{
                        id            = $task.id
                        status        = 'inbox'
                        title         = $task.title
                        subagent_uuid = (Get-MconTaskSubagentUuid -Task $task)
                        task_data_path = $taskContext.task_data_path
                        task_directory = $taskContext.task_directory
                        deliverables_directory = $taskContext.deliverables_directory
                        evidence_directory = $taskContext.evidence_directory
                    }
                }
            }

            if ($summary.inbox) {
                $reason = 'lead_inbox'
                return New-MconDispatchResult -Act $true -Reason $reason -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary -Tasks $allTasks
            }

            return New-MconDispatchResult -Act $false -Reason 'idle' -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary
        }

        'verifier' {
            $reviewUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/tasks?status=review"
            $reviewResponse = Invoke-MconApi -Method Get -Uri $reviewUri -Token $authToken
            $reviewTasks = @(Get-MconResponseItems -Response $reviewResponse)

            $summary.review = ($reviewTasks.Count -gt 0)
            if (-not $summary.review) {
                return New-MconDispatchResult -Act $false -Reason 'idle' -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary
            }

            $leadWorkspacePath = Get-MconLeadWorkspacePath -BoardId $boardId
            $allTasks = @()
            foreach ($task in $reviewTasks) {
                $taskContext = Write-MconTaskContextBundle `
                    -WorkspacePath $workspacePath `
                    -BoardId $boardId `
                    -LeadAgentId $boardId `
                    -InvocationAgentId $invocationAgentId `
                    -BaseUrl $baseUrl `
                    -AuthToken $authToken `
                    -TaskSummary $task `
                    -TaskBundleWorkspacePath $leadWorkspacePath
                $allTasks += [ordered]@{
                    id            = $task.id
                    status        = 'review'
                    title         = $task.title
                    subagent_uuid = (Get-MconTaskSubagentUuid -Task $task)
                    task_data_path = $taskContext.task_data_path
                    task_directory = $taskContext.task_directory
                    deliverables_directory = $taskContext.deliverables_directory
                    evidence_directory = $taskContext.evidence_directory
                }
            }

            return New-MconDispatchResult -Act $true -Reason 'verifier_review' -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary -Tasks $allTasks
        }

        'worker' {
            $assignedInboxUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/tasks?status=inbox&assigned_agent_id=$encodedAgentId"
            $assignedInProgressUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/tasks?status=in_progress&assigned_agent_id=$encodedAgentId"

            $assignedInboxResponse = Invoke-MconApi -Method Get -Uri $assignedInboxUri -Token $authToken
            $assignedInProgressResponse = Invoke-MconApi -Method Get -Uri $assignedInProgressUri -Token $authToken

            $assignedInboxTasks = @(Get-MconResponseItems -Response $assignedInboxResponse | Where-Object { -not (Test-MconTaskBacklog -Task $_) })
            $assignedInProgressTasks = @(Get-MconResponseItems -Response $assignedInProgressResponse | Where-Object { -not (Test-MconTaskBacklog -Task $_) })

            $summary.assignedInbox = ($assignedInboxTasks.Count -gt 0)
            $summary.assignedInProgress = ($assignedInProgressTasks.Count -gt 0)

            $allTasks = @()
            if ($summary.assignedInbox) {
                foreach ($task in $assignedInboxTasks) {
                    $taskContext = Write-MconTaskContextBundle -WorkspacePath $workspacePath -BoardId $boardId -LeadAgentId $boardId -InvocationAgentId $invocationAgentId -BaseUrl $baseUrl -AuthToken $authToken -TaskSummary $task
                    $allTasks += [ordered]@{
                        id            = $task.id
                        status        = 'inbox'
                        title         = $task.title
                        subagent_uuid = (Get-MconTaskSubagentUuid -Task $task)
                        task_data_path = $taskContext.task_data_path
                        task_directory = $taskContext.task_directory
                        deliverables_directory = $taskContext.deliverables_directory
                        evidence_directory = $taskContext.evidence_directory
                    }
                }
                return New-MconDispatchResult -Act $true -Reason 'worker_inbox' -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary -Tasks $allTasks
            }

            if ($summary.assignedInProgress) {
                foreach ($task in $assignedInProgressTasks) {
                    $taskContext = Write-MconTaskContextBundle -WorkspacePath $workspacePath -BoardId $boardId -LeadAgentId $boardId -InvocationAgentId $invocationAgentId -BaseUrl $baseUrl -AuthToken $authToken -TaskSummary $task
                    $allTasks += [ordered]@{
                        id            = $task.id
                        status        = 'in_progress'
                        title         = $task.title
                        subagent_uuid = (Get-MconTaskSubagentUuid -Task $task)
                        task_data_path = $taskContext.task_data_path
                        task_directory = $taskContext.task_directory
                        deliverables_directory = $taskContext.deliverables_directory
                        evidence_directory = $taskContext.evidence_directory
                    }
                }
                return New-MconDispatchResult -Act $true -Reason 'worker_in_progress' -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary -Tasks $allTasks
            }

            return New-MconDispatchResult -Act $false -Reason 'idle' -AgentRole $role -BoardId $boardId -AgentId $agentId -Summary $summary
        }

        default {
            throw "Unsupported agent role: $role"
        }
    }
}

Export-ModuleMember -Function Invoke-MconDispatch, New-MconDispatchResult, Get-MconResponseItems
