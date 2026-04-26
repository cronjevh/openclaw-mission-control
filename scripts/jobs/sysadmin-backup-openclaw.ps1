#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sysadmin OpenClaw backup utility job.

.DESCRIPTION
    Creates compressed, verified backups of OpenClaw configuration, credentials,
    workspaces, and sessions. Enforces retention policy (keep last 30 days).
    Should be scheduled daily.

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
$LogFile = "$LogDir/job-sysadmin-backup-openclaw-$(Get-Date -Format 'yyyyMMdd').log"
$BackupDir = "$HOME/.openclaw/backups"
$MaxBackups = 30

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
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

# ── Backup Creation ─────────────────────────────────────────────────
Write-Log "=== OpenClaw Backup Job Start ==="

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$archiveName = "openclaw-backup-$timestamp.tar.gz"
$archivePath = Join-Path $BackupDir $archiveName

Write-Log "Backup destination: $archivePath"

# Use openclaw backup create if available, otherwise manual tar
if (Get-Command openclaw -ErrorAction SilentlyContinue) {
    Write-Log "Using openclaw backup create command..."
    try {
        $backupResult = openclaw backup create --verify --output $archivePath 2>&1
        Write-Log "Backup command output: $backupResult"
        if (-not (Test-Path $archivePath)) {
            Write-Log "ERROR: Backup file not created"
            exit 1
        }
    } catch {
        Write-Log "ERROR: openclaw backup create failed: $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Log "OpenClaw CLI not found, using manual tar backup..."
    $openclawDir = "$HOME/.openclaw"
    if (-not (Test-Path $openclawDir)) {
        Write-Log "ERROR: OpenClaw directory not found: $openclawDir"
        exit 1
    }

    # Create tar.gz excluding volatile files
    $excludePatterns = @('*.log', '*.tmp', 'cache/*', 'tmp/*')
    $tarArgs = @(
        '-czf', $archivePath
        '-C', (Split-Path $openclawDir -Parent)
        (Split-Path $openclawDir -Leaf)
    )
    # Add excludes
    foreach ($pattern in $excludePatterns) {
        $tarArgs += '--exclude'
        $tarArgs += $pattern
    }

    Write-Log "Running: tar $($tarArgs -join ' ')"
    $tarProcess = Start-Process -FilePath tar -ArgumentList $tarArgs -Wait -PassThru -NoNewWindow
    if ($tarProcess.ExitCode -ne 0) {
        Write-Log "ERROR: tar backup failed with exit code $($tarProcess.ExitCode)"
        exit 1
    }
}

# Verify backup integrity
Write-Log "Verifying backup archive..."
try {
    if (Test-Path $archivePath) {
        $verifyResult = tar -tzf $archivePath > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR: Backup archive verification failed"
            Remove-Item $archivePath -Force
            exit 1
        }
        Write-Log "Backup verified successfully"
    } else {
        Write-Log "ERROR: Backup file not found after creation"
        exit 1
    }
} catch {
    Write-Log "ERROR: Backup verification error: $($_.Exception.Message)"
    exit 1
}

# Get backup size
$backupSizeBytes = (Get-Item $archivePath).Length
$backupSizeMB = [math]::Round($backupSizeBytes / 1MB, 2)
Write-Log "Backup created: $archiveName ($backupSizeMB MB)"

# ── Retention Policy ────────────────────────────────────────────────
Write-Log "Enforcing retention policy (keep last $MaxBackups backups)..."
$backups = Get-ChildItem $BackupDir -Filter "openclaw-backup-*.tar.gz" | Sort-Object CreationTime -Descending
$oldBackups = $backups | Select-Object -Skip $MaxBackups
if ($oldBackups) {
    foreach ($old in $oldBackups) {
        Write-Log "Removing old backup: $($old.Name)"
        Remove-Item $old.FullName -Force
    }
    Write-Log "Removed $($oldBackups.Count) old backups"
} else {
    Write-Log "No old backups to remove (total: $($backups.Count))"
}

# ── Post backup status to board ─────────────────────────────────────
Write-Log "Posting backup status to board..."

try {
    $statusMessage = @"
**Daily Backup Complete**

**Time:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Archive:** $archiveName
**Size:** $backupSizeMB MB
**Location:** $archivePath

Backup verified and retention policy applied.
Total backups retained: $($backups.Count)
"@

    # Find a suitable task to comment on (look for backup-related or any in_progress)
    $tasksUri = "$BaseUrl/api/v1/agent/boards/$BoardId/tasks?status=in_progress&limit=3"
    $tasks = Invoke-McApi -Uri $tasksUri
    $backupTask = $tasks.items | Where-Object { $_.title -like "*backup*" } | Select-Object -First 1

    if ($backupTask) {
        $commentUri = "$BaseUrl/api/v1/boards/$BoardId/tasks/$($backupTask.id)/comments"
        Invoke-McApi -Uri $commentUri -Method 'POST' -Body @{ message = $statusMessage }
        Write-Log "Backup status posted to backup task $($backupTask.id)"
    } elseif ($tasks.items -and $tasks.items.Count -gt 0) {
        # Post to first in_progress task
        $commentUri = "$BaseUrl/api/v1/boards/$BoardId/tasks/$($tasks.items[0].id)/comments"
        Invoke-McApi -Uri $commentUri -Method 'POST' -Body @{ message = $statusMessage }
        Write-Log "Backup status posted to task $($tasks.items[0].id)"
    } else {
        Write-Log "No in_progress tasks found for status update"
    }
} catch {
    Write-Log "WARNING: Could not post backup status: $($_.Exception.Message)"
}

Write-Log "Backup job complete"
exit 0
