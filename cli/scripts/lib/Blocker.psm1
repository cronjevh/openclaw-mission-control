function New-MconBlockerMessage {
    param(
        [Parameter(Mandatory)][string]$BlockerText,
        [Parameter(Mandatory)][string]$EscalationTarget,
        [string]$TaskStatus,
        [string]$RaisedByRole
    )

    $lines = @(
        "Task blocked. $EscalationTarget assistance needed."
        ''
        'Blocker:'
        $BlockerText.Trim()
    )

    if (-not [string]::IsNullOrWhiteSpace($TaskStatus) -or -not [string]::IsNullOrWhiteSpace($RaisedByRole)) {
        $lines += ''
    }

    if (-not [string]::IsNullOrWhiteSpace($TaskStatus)) {
        $lines += "Current status: $TaskStatus"
    }

    if (-not [string]::IsNullOrWhiteSpace($RaisedByRole)) {
        $lines += "Raised by role: $RaisedByRole"
    }

    return ($lines -join "`n")
}

function Invoke-MconBlocker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Role
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id

    $task = Get-MconTask -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId
    $taskStatus = if ($task.PSObject.Properties.Name -contains 'status') { [string]$task.status } else { $null }

    if ($taskStatus -eq 'done') {
        return [ordered]@{
            ok      = $false
            code    = 'invalid_task_state'
            message = 'Cannot raise a blocker on a task that is already done.'
            details = [ordered]@{
                task_id           = $TaskId
                current_status    = $taskStatus
                escalation_target = '@lead'
            }
        }
    }

    $commentMessage = New-MconBlockerMessage -BlockerText $Message -EscalationTarget '@lead' -TaskStatus $taskStatus -RaisedByRole $Role
    $comment = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $commentMessage
    $updatedTask = Set-MconTaskStatus -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Status 'blocked'

    return [ordered]@{
        ok      = $true
        code    = 'blocked'
        message = 'Task marked blocked and escalated to lead.'
        details = [ordered]@{
            task_id           = $TaskId
            previous_status   = $taskStatus
            resulting_status  = $updatedTask.status
            escalation_target = '@lead'
            raised_by_role    = $Role
        }
        comment = $comment
        task    = $updatedTask
    }
}

Export-ModuleMember -Function Invoke-MconBlocker
