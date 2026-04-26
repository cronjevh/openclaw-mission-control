#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sysadmin gateway metrics collection utility job.

.DESCRIPTION
    Collects OpenClaw gateway performance metrics (task throughput, agent status,
    board health) and updates board task or creates metrics report.

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
$LogFile = "$LogDir/job-sysadmin-gateway-metrics-$(Get-Date -Format 'yyyyMMdd').log"

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

# ── Metrics Collection ──────────────────────────────────────────────
Write-Log "=== Gateway Metrics Job Start ==="

$metrics = @{
    timestamp = Get-Date -Format "o"
    boardId = $BoardId
}

# 1. Board snapshot (task counts by status)
Write-Log "Fetching board snapshot..."
try {
    $snapshotUri = "$BaseUrl/api/v1/boards/$BoardId/snapshot"
    $snapshot = Invoke-McApi -Uri $snapshotUri
    $taskCounts = @{}
    foreach ($task in $snapshot.tasks) {
        $status = $task.status
        if (-not $taskCounts.ContainsKey($status)) { $taskCounts[$status] = 0 }
        $taskCounts[$status]++
    }
    $metrics.taskCounts = $taskCounts
    Write-Log "Task counts: $($taskCounts | ConvertTo-Json -Compress)"
} catch {
    Write-Log "ERROR: Failed to fetch board snapshot: $($_.Exception.Message)"
    exit 1
}

# 2. Agent status summary
Write-Log "Fetching agent status..."
try {
    $agentsUri = "$BaseUrl/api/v1/agent/boards/$BoardId/agents"
    $agents = Invoke-McApi -Uri $agentsUri
    $agentSummary = @()
    foreach ($agent in $agents.items) {
        $agentSummary += [PSCustomObject]@{
            name = $agent.name
            status = $agent.status
            is_board_lead = $agent.is_board_lead
            last_seen_at = $agent.last_seen_at
        }
    }
    $metrics.agents = $agentSummary
    Write-Log "Agents: $($agentSummary.Count) total"
} catch {
    Write-Log "WARNING: Could not fetch agent status: $($_.Exception.Message)"
}

# 3. System resource check (local host)
Write-Log "Checking system resources..."
$sysMetrics = @{
    cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    memory = (Get-CimInstance Win32_OperatingSystem)
    disk = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -eq 'C' }
}
$mem = $sysMetrics.memory
$disk = $sysMetrics.disk
$metrics.system = @{
    cpuLoadPercent = [math]::Round($sysMetrics.cpuLoad, 1)
    memoryUsedGB = [math]::Round(($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / 1MB, 2)
    memoryTotalGB = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 2)
    memoryPercent = [math]::Round((($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize) * 100, 1)
    diskUsedGB = [math]::Round($disk.Used / 1GB, 2)
    diskTotalGB = [math]::Round($disk.Total / 1GB, 2)
    diskPercent = [math]::Round(($disk.Used / $disk.Total) * 100, 1)
}
Write-Log "System: CPU=$($metrics.system.cpuLoadPercent)%, Mem=$($metrics.system.memoryPercent)%, Disk=$($metrics.system.diskPercent)%"

# ── Store metrics in board memory or task comment ───────────────────
$metricsJson = $metrics | ConvertTo-Json -Depth 5 -Compress

# Try to find a metrics-dedicated task or create a new one
try {
    $searchUri = "$BaseUrl/api/v1/boards/$BoardId/tasks?search=metrics&limit=3"
    $tasks = Invoke-McApi -Uri $searchUri
    $metricsTask = $tasks.items | Where-Object { $_.title -like "*metrics*" } | Select-Object -First 1

    if ($metricsTask) {
        # Update existing task with latest metrics
        Write-Log "Updating metrics task $($metricsTask.id)"
        $commentBody = @"
**Gateway Metrics Update**

**Time:** $($metrics.timestamp)

**Task Counts:**
$($metrics.taskCounts | ConvertTo-Json -Compress)

**System:**
- CPU: $($metrics.system.cpuLoadPercent)%
- Memory: $($metrics.system.memoryPercent)% used ($($metrics.system.memoryUsedGB)/$($metrics.system.memoryTotalGB) GB)
- Disk: $($metrics.system.diskPercent)% used ($($metrics.system.diskUsedGB)/$($metrics.system.diskTotalGB) GB)

**Agents:** $($metrics.agents.Count) active
"@
        $commentUri = "$BaseUrl/api/v1/boards/$BoardId/tasks/$($metricsTask.id)/comments"
        Invoke-McApi -Uri $commentUri -Method 'POST' -Body @{ message = $commentBody }
        Write-Log "Metrics comment posted to task $($metricsTask.id)"
    } else {
        # Create a new metrics task
        Write-Log "Creating new metrics task..."
        $createUri = "$BaseUrl/api/v1/boards/$BoardId/tasks"
        $taskBody = @{
            title = "Gateway Metrics - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
            description = "Automated gateway metrics collection.`n`nMetrics data:`n```json`n$metricsJson`n```"
            status = 'done'
            priority = 'low'
        } | ConvertTo-Json -Depth 10
        $newTask = Invoke-McApi -Uri $createUri -Method 'POST' -Body $taskBody
        Write-Log "Created metrics task: $($newTask.id)"
    }
} catch {
    Write-Log "ERROR: Failed to store metrics: $($_.Exception.Message)"
    exit 1
}

Write-Log "Gateway metrics job complete"
exit 0
