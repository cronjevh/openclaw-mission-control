#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Daily conversation review utility job.

.DESCRIPTION
    Stages conversation review artifacts (evidence index) for the previous
    calendar day (Africa/Johannesburg timezone), creates a review task on the
    board, and hands off to Rumi (the conversation review specialist) via
    mcon workflow assign.

    If no conversations exist for the target date, the process logs a skip
    message and exits cleanly (no failure).

.PARAMETER BoardId
    The Mission Control board ID.

.PARAMETER AgentId
    The lead agent ID (used for task creation context).

.PARAMETER SpecialistId
    The conversation review specialist agent ID (Rumi). Defaults to
    cf096be4-de67-47f3-8973-0f762683f5e1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BoardId,
    [Parameter(Mandatory)][string]$AgentId,
    [string]$SpecialistId = 'cf096be4-de67-47f3-8973-0f762683f5e1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Config ──────────────────────────────────────────────────────────
$BaseUrl = 'http://localhost:8002'
$Timezone = 'Africa/Johannesburg'
$LeadWorkspace = "/home/cronjev/.openclaw/workspace-lead-$BoardId"
$BuildIndexScript = "$LeadWorkspace/bin/build-session-evidence-index.py"
$ReportsDir = "/home/cronjev/.openclaw/workspace-mc-cf096be4-de67-47f3-8973-0f762683f5e1/reports"
$EvidenceIndex = "$ReportsDir/session-evidence-index.json"

# ── Logging ─────────────────────────────────────────────────────────
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logDir = "$HOME/.openclaw/logs/jobs"
$logFile = "$logDir/job-$(Get-Date -Format 'yyyyMMdd').log"

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $line = "[$timestamp] $Message"
    Write-Output $line
    Add-Content -Path $logFile -Value $line
}

# ── Resolve workspace & auth ────────────────────────────────────────
if (-not (Test-Path $LeadWorkspace)) {
    Write-Log "ERROR: Workspace not found: $LeadWorkspace"
    exit 1
}

# Auth resolution: match Python board helper logic
# Track both the token value and which type it is (for correct header)
$authToken = $null
$authType = $null  # 'agent' for X-Agent-Token, 'bearer' for Authorization: Bearer

if ($env:AUTH_TOKEN) {
    $authToken = $env:AUTH_TOKEN
    $authType = 'agent'
    Write-Log "Using AUTH_TOKEN from environment"
} elseif ($env:LOCAL_AUTH_TOKEN) {
    $authToken = $env:LOCAL_AUTH_TOKEN
    $authType = 'bearer'
    Write-Log "Using LOCAL_AUTH_TOKEN from environment"
} else {
    # Try .env file
    $envFile = '/home/cronjev/mission-control-tfsmrt/.env'
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile -Raw
        if ($envContent -match '(?m)^LOCAL_AUTH_TOKEN\s*=\s*([^\r\n]+?)\s*$') {
            $authToken = $matches[1].Trim().Trim('`', '"', "'")
            $authType = 'bearer'
            Write-Log "Using LOCAL_AUTH_TOKEN from .env file"
        }
    }
}

if (-not $authToken) {
    # Legacy fallback: try TOOLS.md
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
    Write-Log "ERROR: No auth token found (checked env AUTH_TOKEN, LOCAL_AUTH_TOKEN, .env, TOOLS.md)"
    exit 1
}

# ── Determine target date (previous day in Johannesburg) ────────────
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
$nowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
$targetDate = $nowLocal.AddDays(-1).ToString('yyyy-MM-dd')
$taskTitle = "Review $targetDate conversations"

Write-Log "Target date: $targetDate"
Write-Log "Task title: $taskTitle"

# ── API helpers ─────────────────────────────────────────────────────
function Get-AuthHeaders {
    if ($authType -eq 'agent') {
        return @{
            'X-Agent-Token' = $authToken
            'Content-Type' = 'application/json'
        }
    } else {
        return @{
            'Authorization' = "Bearer $authToken"
            'Content-Type' = 'application/json'
        }
    }
}

function Get-BoardApiPath {
    param([string]$Path)
    if ($authType -eq 'agent') {
        return "/api/v1/agent/boards/$BoardId$Path"
    } else {
        return "/api/v1/boards/$BoardId$Path"
    }
}

function Invoke-McApi {
    param([string]$Method = 'GET', [string]$Uri, [object]$Body = $null)
    $params = @{
        Method = $Method
        Uri = $Uri
        Headers = (Get-AuthHeaders)
        TimeoutSec = 30
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    return Invoke-RestMethod @params
}

# ── Phase 1: Check if task already exists ───────────────────────────
$searchPath = Get-BoardApiPath -Path "/tasks?search=$([uri]::EscapeDataString($taskTitle))"
$searchUri = "$BaseUrl$searchPath"

try {
    $existing = Invoke-McApi -Uri $searchUri
    $items = @($existing.items | Where-Object { $_.title -eq $taskTitle })
    if ($items.Count -gt 0) {
        Write-Log "Task already exists: $($items[0].id) — skipping creation"
        exit 0
    }
} catch {
    Write-Log "WARNING: Failed to search existing tasks: $($_.Exception.Message)"
}

# ── Phase 2: Stage artifacts — build session evidence index ─────────
Write-Log "Phase 2: Building session evidence index for $targetDate"

if (-not (Test-Path $BuildIndexScript)) {
    Write-Log "ERROR: Build index script not found: $BuildIndexScript"
    exit 1
}

if (-not (Test-Path $ReportsDir)) {
    New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null
}

python3 $BuildIndexScript --date $targetDate --output $EvidenceIndex
$buildExit = $LASTEXITCODE
if ($buildExit -ne 0) {
    Write-Log "ERROR: Failed to build session evidence index (exit $buildExit)"
    exit 1
}

# ── Phase 3: Check if any sessions exist for the target date ────────
if (-not (Test-Path $EvidenceIndex)) {
    Write-Log "SKIP: No evidence index produced — no conversations to review for $targetDate"
    exit 0
}

$indexData = Get-Content $EvidenceIndex -Raw | ConvertFrom-Json
$sessionFiles = @($indexData.dates.$targetDate)

if ($sessionFiles.Count -eq 0) {
    Write-Log "SKIP: No session files found for $targetDate — nothing to review"
    exit 0
}

Write-Log "Found $($sessionFiles.Count) session files for $targetDate"

# ── Phase 4: Create the review task ────────────────────────────────
Write-Log "Phase 4: Creating review task for $targetDate"

$createPath = Get-BoardApiPath -Path "/tasks"
$createUri = "$BaseUrl$createPath"
$taskBody = @{
    title = $taskTitle
    description = @"
Daily conversation review for $targetDate.

**Staged artifacts:**
- Session evidence index: $EvidenceIndex
- Session files: $($sessionFiles.Count) files indexed

**Expected output from specialist:**
1. A report on the conversations for $targetDate
2. Optionally, a list of task specs for corrective action if issues are found

**Review lanes:** whatsapp_bad_response, vaca_voice, simple_but_slow
"@
    status = 'inbox'
    priority = 'medium'
    custom_field_values = @{
        backlog = $false
    }
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod -Method Post -Uri $createUri -Headers (Get-AuthHeaders) -Body $taskBody -TimeoutSec 30
    $taskId = $response.id
    Write-Log "Created task: $taskId — $taskTitle"
} catch {
    Write-Log "ERROR: Failed to create task: $($_.Exception.Message)"
    exit 1
}

# ── Phase 5: Hand off to specialist via mcon workflow assign ────────
Write-Log "Phase 5: Assigning task $taskId to specialist $SpecialistId"

Push-Location $LeadWorkspace
try {
    mcon workflow assign --task $taskId --worker $SpecialistId --origin-session-key "task:$taskId"
    $assignExit = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($assignExit -ne 0) {
    Write-Log "ERROR: Failed to assign task (exit $assignExit)"
    exit 1
}

Write-Log "Daily conversation review job complete — task $taskId assigned to Rumi"
exit 0
