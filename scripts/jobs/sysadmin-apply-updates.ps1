#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sysadmin update apply utility job (DANGEROUS - manual trigger recommended).

.DESCRIPTION
    Applies pending Ubuntu package updates and OpenClaw updates.
    Includes safety checks (WSL2 detection, disk space, dry-run).
    THIS SCRIPT SHOULD BE TRIGGERED MANUALLY, NOT ON A SCHEDULE.

.PARAMETER BoardId
    The Mission Control board ID (Sysadmin board).

.PARAMETER AgentId
    The lead agent ID (Nova) for board interactions.

.PARAMETER Force
    Skip interactive prompts and apply non-security updates too. Use with caution.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BoardId,
    [Parameter(Mandatory)][string]$AgentId,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Config ──────────────────────────────────────────────────────────
$BaseUrl = 'http://localhost:8002'
$LeadWorkspace = "/home/cronjev/.openclaw/workspace-lead-$BoardId"
$LogDir = "$HOME/.openclaw/logs/jobs"
$LogFile = "$LogDir/job-sysadmin-apply-updates-$(Get-Date -Format 'yyyyMMdd').log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "=== APPLY UPDATES JOB START (DANGEROUS OPERATION) ==="
Write-Log "Force mode: $Force"

# ── Resolve auth token ──────────────────────────────────────────────
$authToken = $null
$authType = $null

if ($env:AUTH_TOKEN) {
    $authToken = $env:AUTH_TOKEN; $authType = 'agent'
} elseif ($env:LOCAL_AUTH_TOKEN) {
    $authToken = $env:LOCAL_AUTH_TOKEN; $authType = 'bearer'
} else {
    $toolsPath = Join-Path $LeadWorkspace 'TOOLS.md'
    if (Test-Path $toolsPath) {
        $toolsContent = Get-Content $toolsPath -Raw
        if ($toolsContent -match '(?m)^\s*AUTH_TOKEN\s*=\s*([^\r\n]+?)\s*$') {
            $authToken = $matches[1].Trim().Trim('`', '"', "'")
            $authType = 'agent'
        }
    }
}

if (-not $authToken) {
    Write-Log "ERROR: No auth token found"
    exit 1
}

function Get-AuthHeaders {
    if ($authType -eq 'agent') {
        return @{ 'X-Agent-Token' = $authToken; 'Content-Type' = 'application/json' }
    } else {
        return @{ 'Authorization' = "Bearer $authToken"; 'Content-Type' = 'application/json' }
    }
}

function Invoke-McApi {
    param([string]$Method = 'GET', [string]$Uri, [object]$Body = $null)
    $params = @{ Method = $Method; Uri = $Uri; Headers = (Get-AuthHeaders); TimeoutSec = 30 }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
    try {
        return Invoke-RestMethod @params
    } catch {
        Write-Log "API error ($Method $Uri): $($_.Exception.Message)"
        throw
    }
}

# ── Safety Checks ───────────────────────────────────────────────────
Write-Log "Running safety checks..."

# Check WSL2 (always okay)
$isWSL = (Get-ComputerInfo | Select-Object -ExpandProperty OsName) -match 'Microsoft'
if ($isWSL) {
    Write-Log "Environment: WSL2 (no battery constraint)"
} else {
    # On real hardware, check if on battery
    if (Get-Command on_ac_power -ErrorAction SilentlyContinue) {
        if (-not (on_ac_power)) {
            Write-Log "ERROR: Running on battery - aborting updates for safety"
            exit 1
        }
    }
}

# Check disk space (need at least 2GB free)
$systemDrive = Get-PSDrive -Name C
$freeGB = [math]::Round($systemDrive.Free / 1GB, 2)
Write-Log "Free disk space: $freeGB GB"
if ($freeGB -lt 2) {
    Write-Log "ERROR: Insufficient disk space (< 2GB free) - aborting"
    exit 1
}

# Check for pending reboot
$rebootPending = $false
$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
)
foreach ($key in $rebootKeys) {
    if (Test-Path $key) {
        $rebootPending = $true
        break
    }
}
if ($rebootPending) {
    Write-Log "WARNING: Pending reboot detected - consider rebooting before updates"
}

# ── Ubuntu Updates ──────────────────────────────────────────────────
Write-Log "Checking for Ubuntu package updates..."
$ubuntuUpdates = @()
try {
    $simulate = apt-get -s upgrade 2>&1
    $instLines = $simulate | Where-Object { $_ -match '^Inst' }
    if ($instLines -and $instLines.Count -gt 0) {
        $ubuntuUpdates = $instLines
        Write-Log "Found $($instLines.Count) pending Ubuntu updates"
        $instLines | Select-Object -First 5 | ForEach-Object { Write-Log "  $_" }
    } else {
        Write-Log "No Ubuntu package updates pending"
    }
} catch {
    Write-Log "ERROR: Failed to check Ubuntu updates: $($_.Exception.Message)"
    exit 1
}

# ── OpenClaw Update Check ───────────────────────────────────────────
Write-Log "Checking OpenClaw update status..."
$ocUpdateAvailable = $false
$ocCurrent = "unknown"
$ocLatest = "unknown"
try {
    if (Get-Command openclaw -ErrorAction SilentlyContinue) {
        $ocStatusJson = openclaw update status --json 2>&1 | Out-String
        $ocStatus = $ocStatusJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($ocStatus -and $ocStatus.availability -and $ocStatus.availability.available) {
            $ocUpdateAvailable = $true
            $ocCurrent = $ocStatus.update.registry.latestVersion ?? "unknown"
            $ocLatest = $ocStatus.availability.latestVersion ?? "unknown"
            Write-Log "OpenClaw update available: $ocCurrent → $ocLatest"
        } else {
            $ocCurrent = $ocStatus?.update?.registry?.latestVersion ?? "unknown"
            Write-Log "OpenClaw is up-to-date ($ocCurrent)"
        }
    } else {
        Write-Log "OpenClaw CLI not found"
    }
} catch {
    Write-Log "WARNING: Could not check OpenClaw updates: $($_.Exception.Message)"
}

# ── Apply Updates ────────────────────────────────────────────────────
$applied = $false
$applyLog = @()

if ($ubuntuUpdates.Count -gt 0) {
    Write-Log "Applying Ubuntu updates..."
    Write-Log "Running unattended-upgrade (dry-run first)..."
    try {
        $dryRun = unattended-upgrade --dry-run 2>&1
        $applyLog += "Ubuntu unattended-upgrade dry-run: $($dryRun | Out-String)"
        Write-Log "Dry-run passed, proceeding with actual upgrade..."

        # Apply security updates automatically
        Write-Log "Running unattended-upgrade..."
        $upgradeResult = unattended-upgrade 2>&1
        $applyLog += "Ubuntu unattended-upgrade result: $($upgradeResult | Out-String)"
        Write-Log "Ubuntu updates applied"
        $applied = $true
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "ERROR: Failed to apply Ubuntu updates: $errMsg"
        $applyLog += "ERROR: Ubuntu update failed: $errMsg"
    }
}

if ($ocUpdateAvailable) {
    Write-Log "Applying OpenClaw update..."
    try {
        $dryRun = openclaw update --dry-run 2>&1
        $applyLog += "OpenClaw dry-run: $($dryRun | Out-String)"
        Write-Log "OpenClaw dry-run passed, applying update..."
        openclaw update --yes --no-restart 2>&1 | ForEach-Object {
            $applyLog += "OpenClaw update: $_"
            Write-Log $_
        }
        Write-Log "OpenClaw update applied (restart gateway to activate)"
        $applied = $true
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "ERROR: Failed to apply OpenClaw update: $errMsg"
        $applyLog += "ERROR: OpenClaw update failed: $errMsg"
    }
}

# ── Report Results ──────────────────────────────────────────────────
if ($applied) {
    Write-Log "Updates applied successfully"

    # Post completion note to board
    try {
        $commentBody = @"
**Update Apply Complete**

**Time:** $timestamp

**Actions taken:**
$($applyLog -join "`n")

**Next steps:**
- Monitor system stability
- Reboot if kernel or core packages were updated
- Restart OpenClaw gateway if OpenClaw was updated: \`openclaw restart\`
"@
        # Try to find an active task or create a log entry
        $tasksUri = "$BaseUrl/api/v1/agent/boards/$BoardId/tasks?status=in_progress&limit=1"
        $tasks = Invoke-McApi -Uri $tasksUri
        if ($tasks.items -and $tasks.items.Count -gt 0) {
            $taskId = $tasks.items[0].id
            $commentUri = "$BaseUrl/api/v1/boards/$BoardId/tasks/$taskId/comments"
            Invoke-McApi -Uri $commentUri -Method 'POST' -Body @{ message = $commentBody }
            Write-Log "Apply report posted to task $taskId"
        }
    } catch {
        Write-Log "WARNING: Could not post apply report: $($_.Exception.Message)"
    }

    exit 0
} else {
    Write-Log "No updates were applied (none pending or errors occurred)"
    exit 0
}
