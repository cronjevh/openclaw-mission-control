#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sysadmin update monitor utility job.

.DESCRIPTION
    Checks for available Ubuntu package updates and OpenClaw updates.
    Posts summary to the Sysadmin board if updates are pending.

.PARAMETER BoardId
    The Mission Control board ID (Sysadmin board).

.PARAMETER AgentId
    The lead agent ID (Nova) for board interactions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BoardId,
    [Parameter(Mandatory)][string]$AgentId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Config ──────────────────────────────────────────────────────────
$BaseUrl = 'http://localhost:8002'
$LeadWorkspace = "/home/cronjev/.openclaw/workspace-lead-$BoardId"
$LogDir = "$HOME/.openclaw/logs/jobs"
$LogFile = "$LogDir/job-sysadmin-update-monitor-$(Get-Date -Format 'yyyyMMdd').log"
$UpdateTaskId = "6de287af-be93-4140-a8b7-9cef7abaaecf"  # Pre-defined update task

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

# ── Update Check ────────────────────────────────────────────────────
Write-Log "=== Update Monitor Job Start ==="

$needsAttention = $false
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$alertMsg = "**Update Check Report**`n`n"
$hasUbuntu = $false
$hasOpenClaw = $false

# 1. Check Ubuntu package updates
Write-Log "Checking Ubuntu package updates..."
try {
    $simulateOutput = apt-get -s upgrade 2>&1
    $instLines = $simulateOutput | Where-Object { $_ -match '^Inst' }
    $ubuntuCount = $instLines.Count
    $securityCount = ($instLines | Where-Object { $_ -match -i 'security' }).Count

    Write-Log "Ubuntu updates: $ubuntuCount total, $securityCount security"

    if ($ubuntuCount -gt 0) {
        $hasUbuntu = $true
        $needsAttention = $true
        $alertMsg += "**Ubuntu**`n"
        $alertMsg += "- Packages pending: $ubuntuCount`n"
        $alertMsg += "- Security updates: $securityCount`n"
        $alertMsg += "- Top packages: $($instLines | Select-Object -First 5 | Out-String -Width 60)`n`n"
    }
} catch {
    Write-Log "WARNING: Failed to check Ubuntu updates: $($_.Exception.Message)"
}

# 2. Check OpenClaw update status
Write-Log "Checking OpenClaw update status..."
try {
    if (Get-Command openclaw -ErrorAction SilentlyContinue) {
        $ocStatusJson = openclaw update status --json 2>&1 | Out-String
        $ocStatus = $ocStatusJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($ocStatus -and $ocStatus.availability -and $ocStatus.availability.available) {
            $hasOpenClaw = $true
            $needsAttention = $true
            $current = $ocStatus.update.registry.latestVersion ?? "unknown"
            $latest = $ocStatus.availability.latestVersion ?? "unknown"
            $alertMsg += "**OpenClaw**`n"
            $alertMsg += "- Update available: $current → $latest`n"
            $alertMsg += "- Run: \`openclaw update --yes\` to apply`n`n"
            Write-Log "OpenClaw update available: $current → $latest"
        } else {
            $current = $ocStatus?.update?.registry?.latestVersion ?? "unknown"
            $alertMsg += "**OpenClaw**`n- Up-to-date ($current)`n"
            Write-Log "OpenClaw is up-to-date ($current)"
        }
    } else {
        Write-Log "OpenClaw CLI not found in PATH"
    }
} catch {
    Write-Log "WARNING: Failed to check OpenClaw updates: $($_.Exception.Message)"
}

# ── Post alert if needed ────────────────────────────────────────────
if ($needsAttention) {
    Write-Log "Updates pending - posting alert to board task $UpdateTaskId"

    $alertMsg += "`nNext step: Review and apply updates via \`~/.openclaw/scripts/apply-updates.sh\` or manually."

    try {
        $commentUri = "$BaseUrl/api/v1/boards/$BoardId/tasks/$UpdateTaskId/comments"
        $commentBody = @{ message = $alertMsg } | ConvertTo-Json -Depth 5
        Invoke-McApi -Uri $commentUri -Method 'POST' -Body $commentBody
        Write-Log "Alert posted successfully"
    } catch {
        Write-Log "ERROR: Failed to post alert: $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Log "No updates pending - system up-to-date"
}

Write-Log "Update monitor job complete"
exit 0
