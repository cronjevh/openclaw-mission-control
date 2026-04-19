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

    try {
        return Invoke-RestMethod @irmParams
    }
    catch {
        $statusCode = $null
        $detail = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
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
        [string[]]$TagIds
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

    return Invoke-MconApi -Method Post -Uri $uri -Token $Token -Body $body
}

Export-ModuleMember -Function Invoke-MconApi, Get-MconTask, Send-MconComment, Set-MconTaskStatus, New-MconTask
