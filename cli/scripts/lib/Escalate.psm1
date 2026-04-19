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

    $isSecretRequest = -not [string]::IsNullOrWhiteSpace($SecretKey)
    $mode = if ($isSecretRequest) { 'request_secret' } else { 'ask_user' }
    $uri = if ($isSecretRequest) {
        "$baseUrl/api/v1/agent/boards/$encodedBoardId/gateway/main/request-secret"
    } else {
        "$baseUrl/api/v1/agent/boards/$encodedBoardId/gateway/main/ask-user"
    }

    $body = [ordered]@{
        content = $Message.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($CorrelationId)) {
        $body.correlation_id = $CorrelationId
    }

    if ($isSecretRequest) {
        $body.secret_key = $SecretKey.Trim().ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($TargetAgentId)) {
            $body.target_agent_id = $TargetAgentId
        }
        if (-not [string]::IsNullOrWhiteSpace($TargetAgentName)) {
            $body.target_agent_name = $TargetAgentName.Trim()
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($PreferredChannel)) {
        $body.preferred_channel = $PreferredChannel.Trim()
    }

    $response = Invoke-MconApi -Method Post -Uri $uri -Token $authToken -Body $body

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
            secret_key        = if ($isSecretRequest) { $body.secret_key } else { $null }
            target_agent_id   = $TargetAgentId
            target_agent_name = $TargetAgentName
            preferred_channel = $PreferredChannel
            correlation_id    = $CorrelationId
        }
        response           = $response
        task_comment       = $taskComment
        task_comment_error = $taskCommentError
    }
}

Export-ModuleMember -Function Invoke-MconEscalate
