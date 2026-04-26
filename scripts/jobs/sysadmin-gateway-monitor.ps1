#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sysadmin gateway monitor utility job.

.DESCRIPTION
    Monitors OpenClaw gateway health, service status, and resource usage.
    Posts alerts to the Sysadmin board if issues are detected.

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
$LogFile = "$LogDir/job-sysadmin-gateway-monitor-$(Get-Date -Format 'yyyyMMdd').log"

# Ensure log directory exists
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
    $authToken = $env:AUTH_TOKEN
    $authType = 'agent'
    Write-Log "Using AUTH_TOKEN from environment"
} elseif ($env:LOCAL_AUTH_TOKEN) {
    $authToken = $env:LOCAL_AUTH_TOKEN
    $authType = 'bearer'
    Write-Log "Using LOCAL_AUTH_TOKEN from environment"
} else {
    $toolsPath = Join-Path $LeadWorkspace 'TOOLS.md'
    if (Test-Path $toolsPath) {
        $toolsContent = Get-Content $toolsPath -Raw
        if ($toolsContent -match '(?m)^\s*AUTH_TOKEN\s*=\s*([^\r\n]+?)\s*$') {
            $authToken = $matches[1].Trim().Trim('`', '"', "'")
            $authType = 'agent'
            Write-Log "Using AUTH_TOKEN from TOOLS.md"
        }
    }
}

if (-not $authToken) {
    Write-Log "ERROR: No auth token found"
    exit 1
}

# ── API helpers ─────────────────────────────────────────────────────
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

# ── Monitoring Logic ────────────────────────────────────────────────
Write-Log "=== Gateway Monitor Job Start ==="

$issues = @()
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# 1. Check gateway service status
Write-Log "Checking gateway service status..."
$gatewayStatus = "unknown"
try {
    $healthUri = "$BaseUrl/healthz"
    $response = Invoke-McApi -Uri $healthUri
    $gatewayStatus = "healthy"
} catch {
    $gatewayStatus = "unhealthy"
    $issues += "Gateway health check failed: $($_.Exception.Message)"
}

# 2. Check agent heartbeat status (Nova)
Write-Log "Checking agent heartbeat (Nova)..."
try {
    $agentPath = "/api/v1/agent/heartbeat"
    $agentUri = "$BaseUrl$agentPath"
    $hbResponse = Invoke-McApi -Uri $agentUri -Method 'POST' -Body @{ status = 'online' }
    Write-Log "Heartbeat sent successfully"
} catch {
    $issues += "Failed to send heartbeat: $($_.Exception.Message)"
}

# 3. Check disk space for critical directories
Write-Log "Checking disk space..."
$criticalPaths = @("$HOME/.openclaw", "/tmp")
foreach ($path in $criticalPaths) {
    if (Test-Path $path) {
        $drive = (Get-Item $path).PSDrive
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        $totalGB = [math]::Round($drive.Used + $drive.Free) / 1GB
        $pctFree = [math]::Round(($drive.Free / ($drive.Used + $drive.Free)) * 100, 1)
        Write-Log "Disk $($drive.Name): $freeGB GB free ($pctFree%)"
        if ($pctFree -lt 10) {
            $issues += "Low disk space on $($drive.Name): $pctFree% free"
        }
    }
}

# 4. Check keybag status (can we decrypt tokens?)
Write-Log "Checking keybag accessibility..."
$keybagPath = "/home/cronjev/mission-control-tfsmrt/cli/scripts/.agent-tokens.json.enc"
if (Test-Path $keybagPath) {
    $keybagSize = (Get-Item $keybagPath).Length
    Write-Log "Keybag present: $keybagSize bytes"
} else {
    $issues += "Keybag not found at $keybagPath"
}

# ── Report results ──────────────────────────────────────────────────
if ($issues.Count -gt 0) {
    Write-Log "ISSUES DETECTED:"
    foreach ($issue in $issues) {
        Write-Log "  - $issue"
    }

    # Post to board task or create alert
    $issueText = $issues -join "`n"
    Write-Log "Posting alert to board..."

    # Try to find an active in_progress task to comment on
    try {
        $tasksUri = "$BaseUrl/api/v1/agent/boards/$BoardId/tasks?status=in_progress&limit=1"
        $tasks = Invoke-McApi -Uri $tasksUri
        if ($tasks.items -and $tasks.items.Count -gt 0) {
            $taskId = $tasks.items[0].id
            $comment = @"
**Gateway Monitor Alert**

**Time:** $timestamp

**Issues:**
$issueText

**Action required:** Investigate and resolve.
"@
            $commentUri = "$BaseUrl/api/v1/boards/$BoardId/tasks/$taskId/comments"
            Invoke-McApi -Uri $commentUri -Method 'POST' -Body @{ message = $comment }
            Write-Log "Alert posted to task $taskId"
        } else {
            Write-Log "No in_progress tasks found to alert on"
        }
    } catch {
        Write-Log "Failed to post alert: $($_.Exception.Message)"
    }

    exit 1
} else {
    Write-Log "All checks passed - gateway healthy"
    exit 0
}
