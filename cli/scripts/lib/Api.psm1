function Invoke-MconApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [object]$Body,
        [int]$TimeoutSec = 20
    )

    $headers = @{
        'X-Agent-Token' = $Token
    }

    $irmParams = @{
        Method     = $Method
        Uri        = $Uri
        Headers    = $headers
        TimeoutSec = $TimeoutSec
    }

    if ($null -ne $Body) {
        $irmParams.ContentType = 'application/json'
        $irmParams.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 -Compress }
    }

    $maxRetries = 3
    $baseDelay = 2

    for ($retryAttempt = 0; $retryAttempt -le $maxRetries; $retryAttempt++) {
        try {
            return Invoke-RestMethod @irmParams
        }
        catch {
            $statusCode = $null
            $detail = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -eq 429) {
                if ($retryAttempt -lt $maxRetries) {
                    $retryAfter = $_.Exception.Response.Headers['Retry-After']
                    if ($retryAfter) {
                        try {
                            $delay = [int]$retryAfter
                        } catch {
                            $delay = $baseDelay * [math]::Pow(2, $retryAttempt)
                        }
                    } else {
                        $delay = $baseDelay * [math]::Pow(2, $retryAttempt)
                    }
                    Write-Warning "429 Too Many Requests. Retrying in $delay seconds... (Attempt $($retryAttempt + 1)/$($maxRetries + 1))"
                    Start-Sleep -Seconds $delay
                    continue
                }
            }
            # If not 429 or max retries reached, handle error
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $detail = ([string]$_.ErrorDetails.Message).Trim()
            }
            if (-not $detail -and $_.Exception.Response -and $_.Exception.Response.Content) {
                try {
                    $detail = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    if ($detail) {
                        $detail = ([string]$detail).Trim()
                    }
                } catch {
                    $detail = $null
                }
            }

            if ($detail) {
                throw "API error: $Method $Uri failed (HTTP $statusCode): $($_.Exception.Message) Response: $detail"
            }

            throw "API error: $Method $Uri failed (HTTP $statusCode): $($_.Exception.Message)"
        }
    }
}

function Get-MconTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask"
    return Invoke-MconApi -Method Get -Uri $uri -Token $Token
}

function Get-MconTaskComments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask/comments"
    $response = Invoke-MconApi -Method Get -Uri $uri -Token $Token
    if ($response.PSObject.Properties.Name -contains 'items') {
        return @($response.items | Where-Object { $null -ne $_ })
    }
    if ($response -is [array]) {
        return @($response)
    }
    return @($response)
}

function Send-MconComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Message
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask/comments"
    $body = @{ message = $Message }
    return Invoke-MconApi -Method Post -Uri $uri -Token $Token -Body $body
}

function Set-MconTaskStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Status
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask"
    $body = @{ status = $Status }
    return Invoke-MconApi -Method Patch -Uri $uri -Token $Token -Body $body
}

function New-MconTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$Title,
        [string]$Description,
        [string]$Priority,
        [Nullable[bool]]$Backlog,
        [string[]]$TagIds,
        [string[]]$DependsOnTaskIds,
        [string]$TaskClass
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks"

    $body = @{
        title = $Title
        status = 'inbox'
    }

    if ($Description) {
        $body.description = $Description
    }

    if ($Priority) {
        $body.priority = $Priority
    }

    if ($null -ne $Backlog) {
        $body.custom_field_values = @{
            backlog = [bool]$Backlog
        }
    }

    if ($TagIds -and $TagIds.Count -gt 0) {
        $body.tag_ids = @($TagIds)
    }

    if ($DependsOnTaskIds -and $DependsOnTaskIds.Count -gt 0) {
        $body.depends_on_task_ids = @($DependsOnTaskIds)
    }

    if ($null -ne $TaskClass) {
        $body.task_class = $TaskClass
    }

    return Invoke-MconApi -Method Post -Uri $uri -Token $Token -Body $body
}

function Set-MconTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId,
        [string]$Title,
        [string]$Description,
        [string]$Priority,
        [Nullable[bool]]$Backlog,
        [string[]]$TagIds,
        [string[]]$DependsOnTaskIds,
        [string]$TaskClass
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask"

    $body = @{}

    if ($Title) {
        $body.title = $Title
    }
    if ($Description) {
        $body.description = $Description
    }
    if ($Priority) {
        $body.priority = $Priority
    }
    if ($null -ne $Backlog) {
        $body.custom_field_values = @{
            backlog = [bool]$Backlog
        }
    }
    if ($TagIds -and $TagIds.Count -gt 0) {
        $body.tag_ids = @($TagIds)
    }
    if ($DependsOnTaskIds -and $DependsOnTaskIds.Count -gt 0) {
        $body.depends_on_task_ids = @($DependsOnTaskIds)
    }
    if ($null -ne $TaskClass) {
        $body.task_class = $TaskClass
    }

    return Invoke-MconApi -Method Patch -Uri $uri -Token $Token -Body $body
}

function Get-MconBoardTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId
    )
    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tags"
    $response = Invoke-MconApi -Method Get -Uri $uri -Token $Token
    if ($response -is [array] -and $response.Count -eq 1 -and $response[0] -is [array]) {
        return @($response[0])
    }
    return @($response)
}

function Get-MconBoardTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TagId
    )
    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTag = [uri]::EscapeDataString($TagId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tags/$encodedTag"
    return Invoke-MconApi -Method Get -Uri $uri -Token $Token
}

function Get-MconBoardTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [string]$Tag,
        [bool]$IncludeHiddenDone = $false,
        [string]$Status,
        [string]$AssignedAgentId,
        [bool]$Unassigned,
        [int]$Limit = 200,
        [int]$Offset = 0
    )
    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks"
    $queryParams = @{}
    if ($PSBoundParameters.ContainsKey('Tag')) { $queryParams['tag'] = $Tag }
    if ($PSBoundParameters.ContainsKey('Status')) { $queryParams['status'] = $Status }
    if ($PSBoundParameters.ContainsKey('AssignedAgentId')) { $queryParams['assigned_agent_id'] = $AssignedAgentId }
    if ($PSBoundParameters.ContainsKey('Unassigned')) { $queryParams['unassigned'] = $Unassigned.ToString().ToLower() }
    $queryParams['include_hidden_done'] = $IncludeHiddenDone.ToString().ToLower()
    $queryParams['limit'] = $Limit
    $queryParams['offset'] = $Offset

    if ($queryParams.Count -gt 0) {
        $queryString = @(
            $queryParams.GetEnumerator() |
            ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }
        ) -join '&'
        $uri = $uri + '?' + $queryString
    }

    $response = Invoke-MconApi -Method Get -Uri $uri -Token $Token
    if ($response.PSObject.Properties.Name -contains 'items') {
        return @($response.items | Where-Object { $null -ne $_ })
    }
    if ($response -is [array]) {
        return @($response)
    }
    return @($response)
}

function Remove-MconTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask"
    return Invoke-MconApi -Method Delete -Uri $uri -Token $Token
}

function Move-MconTaskBetweenBoards {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$TargetBoardId,
        [Parameter(Mandatory)][string]$SourceBoardId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Comment
    )

    $encodedTargetBoard = [uri]::EscapeDataString($TargetBoardId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedTargetBoard/tasks/move-from-board"
    $body = @{
        task_id         = $TaskId
        source_board_id = $SourceBoardId
        comment         = $Comment
    }
    return Invoke-MconApi -Method Post -Uri $uri -Token $Token -Body $body
}

Export-ModuleMember -Function Invoke-MconApi, Get-MconTask, Get-MconTaskComments, Get-MconBoardTags, Get-MconBoardTag, Get-MconBoardTasks, Send-MconComment, Set-MconTaskStatus, New-MconTask, Set-MconTask, Remove-MconTask, Move-MconTaskBetweenBoards
