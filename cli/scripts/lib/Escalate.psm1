function New-MconEscalationTaskCommentMessage {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Message,
        [string]$SecretKey,
        [string]$PreferredChannel
    )

    $lines = @(
        'Escalated to Gateway Main.'
        ''
        "Mode: $Mode"
        'Reason:'
        $Message.Trim()
    )

    if (-not [string]::IsNullOrWhiteSpace($SecretKey)) {
        $lines += "Secret key: $SecretKey"
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredChannel)) {
        $lines += "Preferred channel: $PreferredChannel"
    }

    return ($lines -join "`n")
}

function Get-MconGatewayMainSessionKey {
    param(
        [Parameter(Mandatory)][string]$GatewayId
    )

    return "agent:mc-gateway-${GatewayId}:main"
}

function Get-MconEscalationInvocationAgent {
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ($Config.ContainsKey('workspace_path') -and -not [string]::IsNullOrWhiteSpace([string]$Config.workspace_path)) {
        $workspaceLeaf = Split-Path -Leaf ([string]$Config.workspace_path)
        if ($workspaceLeaf -match '^workspace-(.+)$') {
            return $matches[1]
        }
    }

    if ($Config.ContainsKey('wsp') -and -not [string]::IsNullOrWhiteSpace([string]$Config.wsp)) {
        $workspaceName = [string]$Config.wsp
        if ($workspaceName -match '^workspace-(.+)$') {
            return $matches[1]
        }
    }

    throw 'Unable to resolve invocation agent id from workspace configuration.'
}

function Get-MconEscalationLeadAgent {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId
    )

    $encodedBoardId = [uri]::EscapeDataString($BoardId)
    $rosterResponse = Invoke-MconApi -Method Get -Uri "$BaseUrl/api/v1/agent/agents?board_id=$encodedBoardId&limit=100" -Token $Token
    $agents = @(Get-MconResponseItems -Response $rosterResponse)
    $lead = @($agents | Where-Object { $_ -and $_.is_board_lead } | Select-Object -First 1)
    if ($lead.Count -eq 0 -or -not $lead[0]) {
        throw "No board lead agent found for board $BoardId."
    }

    return $lead[0]
}

function New-MconGatewayReplyMessage {
    param(
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$BoardName,
        [Parameter(Mandatory)][string]$GatewayName,
        [Parameter(Mandatory)][string]$Message,
        [string]$CorrelationId,
        [string]$TaskId
    )

    $correlationLine = if ([string]::IsNullOrWhiteSpace($CorrelationId)) { '' } else { "Correlation ID: $($CorrelationId.Trim())`n" }
    $taskLine = if ([string]::IsNullOrWhiteSpace($TaskId)) { '' } else { "Task ID: $($TaskId.Trim())`n" }

    return @"
GATEWAY MAIN REPLY
Board: $BoardName
Board ID: $BoardId
From gateway: $GatewayName
$correlationLine$taskLine
$($Message.Trim())
"@
}

function New-MconGatewayMainEscalationMessage {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$BoardName,
        [Parameter(Mandatory)][string]$LeadName,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$MconReplyCommand,
        [Parameter(Mandatory)][string]$Message,
        [string]$TaskId,
        [string]$CorrelationId,
        [string]$PreferredChannel,
        [string]$SecretKey,
        [string]$TargetAgentId,
        [string]$TargetAgentName
    )

    $normalizedMessage = $Message.Trim()
    $correlation = if ([string]::IsNullOrWhiteSpace($CorrelationId)) { $null } else { $CorrelationId.Trim() }
    $correlationLine = if ($correlation) { "Correlation ID: $correlation`n" } else { '' }

    if ($Mode -eq 'request_secret') {
        $secret = $SecretKey.Trim().ToUpperInvariant()
        $requestedFor = if (-not [string]::IsNullOrWhiteSpace($TargetAgentName)) {
            "Requested for agent: $($TargetAgentName.Trim())"
        } elseif (-not [string]::IsNullOrWhiteSpace($TargetAgentId)) {
            "Requested for agent id: $($TargetAgentId.Trim())"
        } else {
            'Requested for agent: Board lead'
        }
        $secretLine = "Secret key needed: $secret"

        return @"
LEAD REQUEST: SECRET ACCESS
Board: $BoardName
Board ID: $BoardId
From lead: $LeadName
$correlationLine$secretLine
$requestedFor

$normalizedMessage

Please coordinate with the operator/user to provide or grant this secret.
When resolved (or rejected), deliver the response to the originating lead in BOTH ways:
1. Run this command so the lead receives a direct OpenClaw session message:
$MconReplyCommand --secret-reply --message-file <PATH_CONTAINING_STATUS_OR_SECRET_RESPONSE>
Use --message-file for secrets; do not put secret values directly in shell arguments.
2. Write a NON-chat memory item with status and next steps:
POST $BaseUrl/api/v1/agent/boards/$BoardId/memory
Body: {"content":"<status/update>","tags":["gateway_main","secret_request_reply"],"source":"secret_request_via_gateway_main"}
"@
    }

    $channelLine = if ([string]::IsNullOrWhiteSpace($PreferredChannel)) {
        ''
    } else {
        "Preferred channel: $($PreferredChannel.Trim())`n"
    }

    return @"
LEAD ESCALATION: HUMAN INPUT NEEDED
Board: $BoardName
Board ID: $BoardId
From lead: $LeadName
$correlationLine$channelLine
$normalizedMessage

INBOUND TRIAGE — DO NOT FORWARD TO THE USER YET.

A board lead believes this situation requires human input.
Before contacting any human you MUST:

1. Verify the lead's premise independently — check task state, comments, deliverables, worker workspace, backend logs.
2. Determine if you can resolve this without human involvement — lead management issue, worker deliverable problem, normal workflow friction, or fixable system bug.
3. If you can resolve it: act, then notify the lead via gateway-reply.
4. Only if you have exhausted all remediation avenues and confirmed this genuinely requires a human decision, contact the user via your configured OpenClaw channel(s) (Discord/Slack/SMS/etc). Board chat is a fallback.

When you receive the user's answer, deliver it to the originating lead in BOTH ways:
1. Run: $MconReplyCommand --message "<answer>"
2. Write a NON-chat memory item on this board:
   POST $BaseUrl/api/v1/agent/boards/$BoardId/memory
   Body: {"content":"<answer>","tags":["gateway_main","user_reply"],"source":"user_via_gateway_main"}
"@
}

function Invoke-MconGatewayReply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$Message,
        [string]$TaskId,
        [string]$CorrelationId,
        [ValidateSet('user', 'secret')]
        [string]$ReplyKind = 'user'
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $workspacePath = [string]$Config.workspace_path
    $mconScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'mcon.ps1'
    $encodedBoardId = [uri]::EscapeDataString($BoardId)

    $board = Invoke-MconApi -Method Get -Uri "$baseUrl/api/v1/agent/boards/$encodedBoardId" -Token $authToken
    $boardName = if ($board.PSObject.Properties.Name -contains 'name' -and $board.name) { [string]$board.name } else { $BoardId }
    $lead = Get-MconEscalationLeadAgent -BaseUrl $baseUrl -Token $authToken -BoardId $BoardId
    $leadSessionKey = if ($lead.PSObject.Properties.Name -contains 'openclaw_session_id') { [string]$lead.openclaw_session_id } else { $null }
    if ([string]::IsNullOrWhiteSpace($leadSessionKey)) {
        throw "Board lead for board $BoardId has no openclaw_session_id. Cannot deliver gateway reply."
    }

    $gatewayName = Resolve-MconOpenClawAgentName -WorkspacePath $workspacePath
    $invocationAgent = Get-MconEscalationInvocationAgent -Config $Config
    $replyMessage = New-MconGatewayReplyMessage `
        -BoardId $BoardId `
        -BoardName $boardName `
        -GatewayName $gatewayName `
        -Message $Message `
        -CorrelationId $CorrelationId `
        -TaskId $TaskId

    if ($ReplyKind -eq 'secret') {
        $tags = @('gateway_main', 'secret_request_reply')
        $source = 'secret_request_via_gateway_main'
    } else {
        $tags = @('gateway_main', 'user_reply')
        $source = 'gateway_main_reply'
    }
    $memoryBody = [ordered]@{
        content = $Message.Trim()
        tags    = $tags
        source  = $source
    }
    $memory = Invoke-MconApi -Method Post -Uri "$baseUrl/api/v1/agent/boards/$encodedBoardId/memory" -Token $authToken -Body $memoryBody

    $diagnosticsDir = if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        Join-Path (Join-Path (Join-Path $workspacePath 'tasks') $TaskId) 'evidence/session-dispatch-gateway-reply'
    } else {
        Join-Path $workspacePath '.openclaw/workflows/gateway-reply'
    }
    $dispatchTaskId = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $TaskId } else { [guid]::NewGuid().Guid }
    $dispatchType = 'gateway_reply'
    $deferredPayload = [ordered]@{
        workspace_path        = $workspacePath
        invocation_agent      = $invocationAgent
        session_key           = $leadSessionKey
        message               = $replyMessage
        task_id               = $TaskId
        dispatch_type         = $dispatchType
        timeout_seconds       = 120
        temperature           = 0
        initial_delay_seconds = 0
    }
    $dispatch = Start-MconDeferredSessionDispatch `
        -WorkspacePath $workspacePath `
        -MconScriptPath $mconScriptPath `
        -DiagnosticsDir $diagnosticsDir `
        -TaskId $dispatchTaskId `
        -Payload $deferredPayload

    return [ordered]@{
        ok               = $true
        board_id         = $BoardId
        board_name       = $boardName
        lead_agent_id    = if ($lead.PSObject.Properties.Name -contains 'id') { [string]$lead.id } else { $null }
        lead_agent_name  = if ($lead.PSObject.Properties.Name -contains 'name') { [string]$lead.name } else { $null }
        lead_session_key = $leadSessionKey
        correlation_id   = $CorrelationId
        task_id          = $TaskId
        memory           = $memory
        dispatch         = $dispatch
    }
}

function Invoke-MconEscalate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Message,
        [string]$TaskId,
        [string]$SecretKey,
        [string]$TargetAgentId,
        [string]$TargetAgentName,
        [string]$PreferredChannel,
        [string]$CorrelationId
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id
    $encodedBoardId = [uri]::EscapeDataString($boardId)
    $workspacePath = [string]$Config.workspace_path
    $mconScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'mcon.ps1'

    $isSecretRequest = -not [string]::IsNullOrWhiteSpace($SecretKey)
    $mode = if ($isSecretRequest) { 'request_secret' } else { 'ask_user' }

    $board = Invoke-MconApi -Method Get -Uri "$baseUrl/api/v1/agent/boards/$encodedBoardId" -Token $authToken
    $gatewayId = if ($board.PSObject.Properties.Name -contains 'gateway_id') { [string]$board.gateway_id } else { $null }
    if ([string]::IsNullOrWhiteSpace($gatewayId)) {
        throw "Board $boardId has no gateway_id. Cannot resolve Gateway Main session."
    }

    $boardName = if ($board.PSObject.Properties.Name -contains 'name' -and $board.name) { [string]$board.name } else { $boardId }
    $leadName = Resolve-MconOpenClawAgentName -WorkspacePath $workspacePath
    $invocationAgent = Get-MconEscalationInvocationAgent -Config $Config
    $sessionKey = Get-MconGatewayMainSessionKey -GatewayId $gatewayId
    $replyCommandParts = @('mcon', 'workflow', 'gateway-reply', '--board', $boardId)
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $replyCommandParts += @('--task', $TaskId)
    }
    if (-not [string]::IsNullOrWhiteSpace($CorrelationId)) {
        $replyCommandParts += @('--correlation-id', $CorrelationId)
    }
    $replyCommand = $replyCommandParts -join ' '
    $messageText = New-MconGatewayMainEscalationMessage `
        -Mode $mode `
        -BoardId $boardId `
        -BoardName $boardName `
        -LeadName $leadName `
        -BaseUrl $baseUrl `
        -MconReplyCommand $replyCommand `
        -Message $Message `
        -TaskId $TaskId `
        -CorrelationId $CorrelationId `
        -PreferredChannel $PreferredChannel `
        -SecretKey $SecretKey `
        -TargetAgentId $TargetAgentId `
        -TargetAgentName $TargetAgentName

    $diagnosticsDir = if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        Join-Path (Join-Path (Join-Path $workspacePath 'tasks') $TaskId) 'evidence/session-dispatch-escalate'
    } else {
        Join-Path $workspacePath '.openclaw/workflows/escalate'
    }
    $dispatchType = "escalate_$mode"
    $deferredPayload = [ordered]@{
        workspace_path        = $workspacePath
        invocation_agent      = $invocationAgent
        session_key           = $sessionKey
        message               = $messageText
        task_id               = $TaskId
        dispatch_type         = $dispatchType
        timeout_seconds       = 120
        temperature           = 0
        initial_delay_seconds = 0
    }
    $response = Start-MconDeferredSessionDispatch `
        -WorkspacePath $workspacePath `
        -MconScriptPath $mconScriptPath `
        -DiagnosticsDir $diagnosticsDir `
        -TaskId $(if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $TaskId } else { [guid]::NewGuid().Guid }) `
        -Payload $deferredPayload

    $taskComment = $null
    $taskCommentError = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $commentMessage = New-MconEscalationTaskCommentMessage -Mode $mode -Message $Message -SecretKey $SecretKey -PreferredChannel $PreferredChannel
        try {
            $taskComment = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $commentMessage
        } catch {
            $taskCommentError = $_.Exception.Message
        }
    }

    return [ordered]@{
        ok      = $true
        code    = $mode
        message = if ($isSecretRequest) {
            'Escalation sent to Gateway Main for missing secret access.'
        } else {
            'Escalation sent to Gateway Main for user input.'
        }
        details = [ordered]@{
            mode              = $mode
            task_id           = $TaskId
            secret_key        = if ($isSecretRequest) { $SecretKey.Trim().ToUpperInvariant() } else { $null }
            target_agent_id   = $TargetAgentId
            target_agent_name = $TargetAgentName
            preferred_channel = $PreferredChannel
            correlation_id    = $CorrelationId
            gateway_id        = $gatewayId
            session_key       = $sessionKey
            queued            = $true
            dispatch_type     = $dispatchType
        }
        response           = $response
        task_comment       = $taskComment
        task_comment_error = $taskCommentError
    }
}

Export-ModuleMember -Function Invoke-MconEscalate, Invoke-MconGatewayReply
