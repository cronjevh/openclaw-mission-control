#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sysadmin logs monitor utility job.

.DESCRIPTION
    Monitors OpenClaw logs for errors and warnings, aggregates findings,
    and posts summary to the Sysadmin board.

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
$LogFile = "$LogDir/job-sysadmin-logs-monitor-$(Get-Date -Format 'yyyyMMdd').log"
$OpenClawLogDir = "$HOME/.openclaw/logs"

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

# ── Logs Monitoring ─────────────────────────────────────────────────
Write-Log "=== Logs Monitor Job Start ==="

$issues = @()
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# 1. Check OpenClaw gateway log for recent errors (last 100 lines)
$gatewayLog = "$OpenClawLogDir/gateway.log"
if (Test-Path $gatewayLog) {
    Write-Log "Checking gateway log: $gatewayLog"
    $recentLines = Get-Content $gatewayLog -Tail 100
    $errorLines = $recentLines | Where-Object { $_ -match 'ERROR|CRITICAL|FATAL' }
    $warningLines = $recentLines | Where-Object { $_ -match 'WARNING|WARN' }

    if ($errorLines -and $errorLines.Count -gt 0) {
        $issues += "Gateway errors detected ($($errorLines.Count)): $($errorLines | Select-Object -First 3 | Out-String)"
    }
    if ($warningLines -and $warningLines.Count -gt 0) {
        Write-Log "Gateway warnings: $($warningLines.Count) in last 100 lines"
    }
} else {
    Write-Log "Gateway log not found at $gatewayLog"
}

# 2. Check agent logs (Nova, IronMan, Vision)
$agentLogDir = "$HOME/.openclaw/logs/agents"
if (Test-Path $agentLogDir) {
    Write-Log "Checking agent logs..."
    $agentLogs = Get-ChildItem $agentLogDir -Filter "*.log" -ErrorAction SilentlyContinue
    foreach ($log in $agentLogs) {
        $agentName = $log.BaseName
        $recent = Get-Content $log.FullName -Tail 50 -ErrorAction SilentlyContinue
        $agentErrors = $recent | Where-Object { $_ -match 'ERROR|CRITICAL|FATAL' }
        if ($agentErrors -and $agentErrors.Count -gt 0) {
            $issues += "Agent $agentName errors: $($agentErrors.Count) recent (sample: $($agentErrors[0]))"
        }
    }
} else {
    Write-Log "Agent log directory not found: $agentLogDir"
}

# 3. Check for log rotation needs (file size)
if (Test-Path $gatewayLog) {
    $logSizeMB = (Get-Item $gatewayLog).Length / 1MB
    Write-Log "Gateway log size: $([math]::Round($logSizeMB, 2)) MB"
    if ($logSizeMB -gt 100) {
        $issues += "Gateway log large ($([math]::Round($logSizeMB, 1)) MB) - consider rotation"
    }
}

# ── Report findings ─────────────────────────────────────────────────
if ($issues.Count -gt 0) {
    Write-Log "ISSUES DETECTED:"
    foreach ($issue in $issues) {
        Write-Log "  - $issue"
    }

    # Post to board
    try {
        $tasksUri = "$BaseUrl/api/v1/agent/boards/$BoardId/tasks?status=in_progress&limit=1"
        $tasks = Invoke-McApi -Uri $tasksUri
        if ($tasks.items -and $tasks.items.Count -gt 0) {
            $taskId = $tasks.items[0].id
            $commentBody = @"
**Logs Monitor Alert**

**Time:** $timestamp

**Issues Found:**
$($issues -join "`n")

**Recommended actions:**
- Review gateway and agent logs in detail
- Check for recurring error patterns
- Consider log rotation if files are large
"@
            $commentUri = "$BaseUrl/api/v1/boards/$BoardId/tasks/$taskId/comments"
            Invoke-McApi -Uri $commentUri -Method 'POST' -Body @{ message = $commentBody }
            Write-Log "Alert posted to task $taskId"
        } else {
            Write-Log "No in_progress tasks to alert on"
        }
    } catch {
        Write-Log "Failed to post alert: $($_.Exception.Message)"
    }

    exit 1
} else {
    Write-Log "No critical log issues detected"
    exit 0
}
