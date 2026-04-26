#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sysadmin OpenClaw restore utility job (DANGEROUS - MANUAL TRIGGER ONLY).

.DESCRIPTION
    Restores OpenClaw state from a backup archive.
    THIS IS A DESTRUCTIVE OPERATION - will overwrite current config and workspaces.
    A pre-restore backup is automatically created as a safety measure.

    THIS JOB SHOULD NEVER BE SCHEDULED - only trigger manually via board task.

.PARAMETER BoardId
    The Mission Control board ID (Sysadmin board).

.PARAMETER AgentId
    The lead agent ID (Nova) for board interactions.

.PARAMETER ArchivePath
    Path to the backup archive (.tar.gz) to restore from.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BoardId,
    [Parameter(Mandatory)][string]$AgentId,
    [Parameter(Mandatory)][string]$ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Config ──────────────────────────────────────────────────────────
$BaseUrl = 'http://localhost:8002'
$LeadWorkspace = "/home/cronjev/.openclaw/workspace-lead-$BoardId"
$LogDir = "$HOME/.openclaw/logs/jobs"
$LogFile = "$LogDir/job-sysadmin-restore-openclaw-$(Get-Date -Format 'yyyyMMdd').log"

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

Write-Log "=== OPENCLAW RESTORE JOB START (DESTRUCTIVE OPERATION) ==="
Write-Log "Archive: $ArchivePath"

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
Write-Log "Performing safety checks..."

# 1. Verify archive exists and is readable
if (-not (Test-Path $ArchivePath)) {
    Write-Log "ERROR: Archive not found: $ArchivePath"
    exit 1
}

# 2. Verify archive integrity
Write-Log "Verifying archive integrity..."
try {
    $tarTest = tar -tzf $ArchivePath > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Archive is corrupted or invalid format"
        exit 1
    }
    Write-Log "Archive verified OK"
} catch {
    Write-Log "ERROR: Archive verification failed: $($_.Exception.Message)"
    exit 1
}

# 3. Create pre-restore backup automatically
$preRestoreDir = "$HOME/.openclaw/pre-restore-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Log "Creating pre-restore backup at: $preRestoreDir"
New-Item -ItemType Directory -Path $preRestoreDir -Force | Out-Null

$criticalFiles = @(
    "$HOME/.openclaw/openclaw.json",
    "$HOME/.openclaw/credentials"
)
foreach ($file in $criticalFiles) {
    if (Test-Path $file) {
        Copy-Item $file $preRestoreDir -Force
        Write-Log "  Backed up: $(Split-Path $file -Leaf)"
    }
}

# 4. Confirm restore is intended (safety)
Write-Log "WARNING: This will OVERWRITE current OpenClaw state!"
Write-Log "Pre-restore backup saved to: $preRestoreDir"
Write-Log "Proceeding with restore in 5 seconds..."
Start-Sleep -Seconds 5

# ── Restore Process ─────────────────────────────────────────────────
Write-Log "Extracting archive..."
$extractDir = "$HOME/.openclaw/restore-extract-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

try {
    tar -xzf $ArchivePath -C $extractDir
    if ($LASTEXITCODE -ne 0) {
        throw "tar extraction failed with exit code $LASTEXITCODE"
    }
    Write-Log "Archive extracted to: $extractDir"
} catch {
    Write-Log "ERROR: Failed to extract archive: $($_.Exception.Message)"
    exit 1
}

# Find payload directory (expected structure: payload/posix/home/cronjev/.openclaw/)
Write-Log "Locating payload directory..."
$payloadDir = Get-ChildItem $extractDir -Recurse -Directory -Filter "payload" | Select-Object -First 1
if (-not $payloadDir) {
    Write-Log "ERROR: Invalid backup structure - no 'payload' directory found"
    exit 1
}
Write-Log "Found payload at: $($payloadDir.FullName)"

# Determine source path (should be payload/posix/home/cronjev/.openclaw/)
$expectedSource = Join-Path $payloadDir.FullName "posix/home/cronjev/.openclaw"
if (Test-Path $expectedSource) {
    $sourcePath = $expectedSource
} else {
    # Fallback: use first .openclaw directory found under payload
    $sourcePath = Get-ChildItem $payloadDir.FullName -Recurse -Directory -Filter ".openclaw" | Select-Object -First 1
    if (-not $sourcePath) {
        Write-Log "ERROR: Could not find .openclaw directory in payload"
        exit 1
    }
    $sourcePath = $sourcePath.FullName
}
Write-Log "Restore source: $sourcePath"

# ── Execute Restore ─────────────────────────────────────────────────
Write-Log "Copying restored files to ~/.openclaw (this will overwrite existing files)..."

try {
    # Use robocopy for robust sync (available on Windows/WSL2)
    if (Get-Command robocopy -ErrorAction SilentlyContinue) {
        $robocopyArgs = @(
            $sourcePath,
            "$HOME/.openclaw",
            '/MIR',
            '/R:1',
            '/W:1',
            '/NFL',
            '/NDL',
            '/NP'
        )
        $rc = robocopy @robocopyArgs
        # Robocopy exit codes: 0-7 are success (0 = no copy, 1 = copied, etc.)
        if ($rc -ge 8) {
            throw "robocopy failed with exit code $rc"
        }
        Write-Log "Restore completed via robocopy"
    } else {
        # Fallback to rsync or copy
        if (Get-Command rsync -ErrorAction SilentlyContinue) {
            rsync -a --delete "$sourcePath/" "$HOME/.openclaw/"
            if ($LASTEXITCODE -ne 0) {
                throw "rsync failed with exit code $LASTEXITCODE"
            }
        } else {
            # Simple copy (less safe)
            Copy-Item -Path "$sourcePath/*" -Destination "$HOME/.openclaw/" -Recurse -Force
        }
        Write-Log "Restore completed via file copy"
    }
} catch {
    Write-Log "ERROR: Restore failed: $($_.Exception.Message)"
    exit 1
}

# Cleanup
Write-Log "Cleaning up temporary files..."
Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Log "Restore complete!"
Write-Log "Pre-restore backup saved at: $preRestoreDir"
Write-Log "VERIFY: Run 'openclaw health' and check services"

# ── Post restore status ─────────────────────────────────────────────
try {
    $statusMessage = @"
**OpenClaw Restore Complete**

**Time:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Source archive:** $ArchivePath
**Pre-restore backup:** $preRestoreDir

**Action required:**
1. Run \`openclaw health\` to verify system health
2. Check gateway status: \`systemctl status openclaw-gateway\` (or equivalent)
3. Review board tasks for any inconsistencies
4. If issues detected, restore from pre-restore backup in: $preRestoreDir
"@

    # Post to board
    $tasksUri = "$BaseUrl/api/v1/agent/boards/$BoardId/tasks?status=in_progress&limit=1"
    $tasks = Invoke-McApi -Uri $tasksUri
    if ($tasks.items -and $tasks.items.Count -gt 0) {
        $taskId = $tasks.items[0].id
        $commentUri = "$BaseUrl/api/v1/boards/$BoardId/tasks/$taskId/comments"
        Invoke-McApi -Uri $commentUri -Method 'POST' -Body @{ message = $statusMessage }
        Write-Log "Restore status posted to task $taskId"
    }
} catch {
    Write-Log "WARNING: Could not post restore status: $($_.Exception.Message)"
}

Write-Log "Restore job complete - system should be verified manually"
exit 0
