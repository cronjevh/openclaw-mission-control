function Invoke-MconAdminCron {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][int]$CadenceMinutes,
        [string]$CrontabDir = '/etc/cron.d',
        [switch]$DryRun
    )

    if ($CadenceMinutes -lt 0) {
        throw "Cadence must be >= 0. Got: $CadenceMinutes"
    }
    if ($CadenceMinutes -gt 1440) {
        throw "Cadence cannot exceed 1440 minutes (24h). Got: $CadenceMinutes"
    }

    $headers = @{
        Authorization = "Bearer $AuthToken"
        Accept        = 'application/json'
    }

    $encodedBoardId = [uri]::EscapeDataString($BoardId)
    $boardUri = "$BaseUrl/api/v1/boards/$encodedBoardId"
    $membersUri = "$boardUri/members"

    $board = $null
    try {
        $board = Invoke-RestMethod -Method Get -Uri $boardUri -Headers $headers -TimeoutSec 20
    } catch {
        throw "Failed to fetch board from $boardUri : $($_.Exception.Message)"
    }

    if (-not $board) {
        throw "Board not found: $BoardId"
    }

    $previousCadence = $null
    if ($board.PSObject.Properties.Name -contains 'cadence_minutes') {
        $previousCadence = $board.cadence_minutes
    }

    if ($previousCadence -eq $CadenceMinutes) {
        return [ordered]@{
            ok               = $true
            action           = 'admin.cron'
            board_id         = $BoardId
            board_name       = $board.name
            cadence_minutes  = $CadenceMinutes
            workers          = 0
            crontab_path     = $null
            status           = 'unchanged'
            message          = "Cadence is already $CadenceMinutes minutes. No update needed."
        }
    }

    $patchBody = @{ cadence_minutes = $CadenceMinutes } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Patch -Uri $boardUri -Headers $headers -ContentType 'application/json' -Body $patchBody -TimeoutSec 20 | Out-Null
    } catch {
        throw "Failed to update board cadence: $($_.Exception.Message)"
    }

    $workers = @()
    try {
        $membersResponse = Invoke-RestMethod -Method Get -Uri $membersUri -Headers $headers -TimeoutSec 20
        if ($membersResponse.PSObject.Properties.Name -contains 'items') {
            $workers = @($membersResponse.items | Where-Object { $null -ne $_ })
        }
    } catch {
        throw "Failed to fetch board members: $($_.Exception.Message)"
    }

    if ($CadenceMinutes -eq 0) {
        $crontabContent = @(
            '# Mission Control board automation'
            "# Board: $($board.name) ($BoardId)"
            "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            '# DO NOT EDIT MANUALLY - changes will be overwritten'
            ''
            '# Cadence set to 0 - no dispatch entries generated'
            ''
        ) -join "`n"

        $crontabPath = $null
        if (-not $DryRun) {
            $shortId = $BoardId.Substring(0, 8)
            $crontabPath = Join-Path $CrontabDir "mission-control-board-$shortId"
            if (Test-Path -LiteralPath $crontabPath) {
                Remove-Item -LiteralPath $crontabPath -Force
            }
        }

        return [ordered]@{
            ok              = $true
            action          = 'admin.cron'
            board_id        = $BoardId
            board_name      = $board.name
            cadence_minutes = $CadenceMinutes
            previous_cadence = $previousCadence
            workers         = $workers.Count
            crontab_path    = $crontabPath
            status          = 'disabled'
            message         = 'Cadence set to 0. Crontab file removed.'
        }
    }

    $crontabLines = @(
        '# Mission Control board automation'
        "# Board: $($board.name) ($BoardId)"
        "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        '# DO NOT EDIT MANUALLY - changes will be overwritten'
        ''
    )

    foreach ($worker in $workers) {
        $workerId = if ($worker.PSObject.Properties.Name -contains 'id') { $worker.id } else { 'unknown' }
        $schedule = "*/$CadenceMinutes * * * *"
        $workspaceDir = "/home/cronjev/.openclaw/workspace-mc-$workerId"
        $crontabLines += "$schedule cronjev cd $workspaceDir && /home/cronjev/bin/mcon workflow dispatch"
    }
    $crontabLines += ''

    $crontabContent = $crontabLines -join "`n"

    $crontabPath = $null
    if (-not $DryRun) {
        $shortId = $BoardId.Substring(0, 8)
        $crontabPath = Join-Path $CrontabDir "mission-control-board-$shortId"

        if (-not (Test-Path -LiteralPath $CrontabDir)) {
            throw "Crontab directory does not exist: $CrontabDir"
        }

        $crontabContent | Set-Content -LiteralPath $crontabPath -Encoding ASCII -Force
        chmod 644 $crontabPath 2>$null
    }

    return [ordered]@{
        ok              = $true
        action          = 'admin.cron'
        board_id        = $BoardId
        board_name      = $board.name
        cadence_minutes = $CadenceMinutes
        previous_cadence = $previousCadence
        workers         = $workers.Count
        crontab_path    = $crontabPath
        crontab_content = if ($DryRun) { $crontabContent } else { $null }
        status          = 'updated'
    }
}

Export-ModuleMember -Function Invoke-MconAdminCron
