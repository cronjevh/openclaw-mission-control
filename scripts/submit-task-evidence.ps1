#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Submit a task deliverable evidence packet — centralized canonical version.
.DESCRIPTION
    Builds and POSTs a task evidence packet using the agent-scoped endpoint.
    This is the single source of truth for evidence submission across all Mission Control agents.

    Key features:
    - Works for any agent (worker or lead) using their own AUTH_TOKEN
    - Automatically resolves lead workspace from BOARD_ID
    - Constructs correct relative_path for lead's task bundle: tasks/<TASK_ID>/deliverables/<filename>
    - Uses agent-scoped endpoint exclusively (no admin fallback)
    - Includes -Verify flag for dry-run testing

    This script replaces all workspace-local copies of submit-task-evidence.ps1.
    Agents should call this via a symlink or wrapper from their bin/ directory.
.PARAMETER TaskId
    Task UUID (required).
.PARAMETER ArtifactPath
    Path to the primary deliverable file, relative to the lead's task bundle deliverables/ directory.
    Example: deliverables/my-fix.md
    The file must already exist in the lead's task bundle.
.PARAMETER Summary
    Short summary of what was completed (required).
.PARAMETER CheckKind
    Optional verification check kind (syntax, functional, integration, security, performance).
.PARAMETER CheckLabel
    Optional label for the check (defaults to CheckKind).
.PARAMETER CheckStatus
    Verification check status. Default 'passed'.
.PARAMETER CheckCommand
    Optional command that was run for the check.
.PARAMETER CheckResultSummary
    Optional summary text for the check result.
.PARAMETER BoardId
    Board UUID. Reads from agent's TOOLS.md if omitted.
.PARAMETER ApiToken
    Agent AUTH_TOKEN. Reads from agent's TOOLS.md if omitted.
.PARAMETER BaseUrl
    Base API URL. Defaults to http://localhost:8002.
.PARAMETER Verify
    If set, performs validation and prints the payload without posting.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ArtifactPath,
    [Parameter(Mandatory = $true)][string]$Summary,
    [Parameter(Mandatory = $false)][string]$CheckKind,
    [Parameter(Mandatory = $false)][string]$CheckLabel,
    [Parameter(Mandatory = $false)][string]$CheckStatus = 'passed',
    [Parameter(Mandatory = $false)][string]$CheckCommand,
    [Parameter(Mandatory = $false)][string]$CheckResultSummary,
    [Parameter(Mandatory = $false)][string]$BoardId,
    [Parameter(Mandatory = $false)][string]$ApiToken,
    [Parameter(Mandatory = $false)][string]$BaseUrl = 'http://localhost:8002',
    [Parameter(Mandatory = $false)][switch]$Verify
)

$ErrorActionPreference = 'Stop'

function Get-LeadWorkspacePath {
    param([string]$BoardId)
    if (-not $BoardId) {
        throw "BOARD_ID is required to determine lead workspace"
    }
    return "/home/cronjev/.openclaw/workspace-lead-${BoardId}"
}

function Find-AgentWorkspace {
    # Start from current location and walk up to find TOOLS.md
    $dir = Get-Location
    while ($dir -and $dir.Path -ne '/') {
        if (Test-Path (Join-Path $dir.Path 'TOOLS.md')) {
            return $dir.Path
        }
        $dir = Split-Path $dir.Path -Parent
    }
    # If not found, try common workspace patterns
    $commonPaths = @(
        '/home/cronjev/.openclaw/workspace-vulcan',
        '/home/cronjev/.openclaw/workspace-mc-466803cc-1793-45e6-9dc0-437c505d49b4',
        '/home/cronjev/.openclaw/workspace-lead-dd95369d-1497-41f2-8aeb-e06b51b63162',
        '/home/cronjev/.openclaw/workspace-hermes',
        '/home/cronjev/.openclaw/workspace/athena'
    )
    foreach ($p in $commonPaths) {
        if (Test-Path (Join-Path $p 'TOOLS.md')) {
            return $p
        }
    }
    throw "Could not locate agent workspace (TOOLS.md not found). Run from workspace root or ensure symlink is in bin/"
}

function Get-ToolsMap {
    param([string]$RootPath)
    $toolsPath = Join-Path $RootPath 'TOOLS.md'
    if (-not (Test-Path $toolsPath)) {
        return @{}
    }
    $map = @{}
    foreach ($line in Get-Content $toolsPath) {
        if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$') {
            $map[$matches[1]] = $matches[2].Trim().Trim('`','"','''')
        }
    }
    return $map
}

function Normalize-List {
    param([object]$Value)
    if ($null -eq $Value) { return ,@() }
    $items = @()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $text = "$item".Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $items += $text
    }
    return ,$items
}

# Find agent workspace (caller's context)
$agentWorkspace = Find-AgentWorkspace
$agentTools = Get-ToolsMap -RootPath $agentWorkspace

# Resolve agent credentials from agent's own TOOLS.md
$agentToken = if ($ApiToken) { $ApiToken } elseif ($agentTools.ContainsKey('AUTH_TOKEN')) { $agentTools['AUTH_TOKEN'] } else { $null }
$agentName = if ($agentTools.ContainsKey('AGENT_NAME')) { $agentTools['AGENT_NAME'] } else { $null }
$agentId = if ($agentTools.ContainsKey('AGENT_ID')) { $agentTools['AGENT_ID'] } else { $null }

# Resolve board/lead context
$boardId = if ($BoardId) { $BoardId } elseif ($agentTools.ContainsKey('BOARD_ID')) { $agentTools['BOARD_ID'] } else { $null }
$leadWorkspace = Get-LeadWorkspacePath -BoardId $boardId
$leadTools = Get-ToolsMap -RootPath $leadWorkspace

# If boardId still not set, try lead's TOOLS.md (should have it)
if (-not $boardId -and $leadTools.ContainsKey('BOARD_ID')) {
    $boardId = $leadTools['BOARD_ID']
}

# Validate required values
if (-not $agentToken) {
    throw "AUTH_TOKEN not found; provide -ApiToken or ensure TOOLS.md in agent workspace ($agentWorkspace) contains AUTH_TOKEN"
}
if (-not $boardId) {
    throw "BOARD_ID not found; provide -BoardId or ensure TOOLS.md in agent or lead workspace contains BOARD_ID"
}

# Validate artifact path format
if (-not ($ArtifactPath -match '^deliverables/')) {
    Write-Warning "ArtifactPath should start with 'deliverables/' (e.g., deliverables/my-file.md). Got: $ArtifactPath"
}

# Build API URLs
$headers = @{ 'X-Agent-Token' = $agentToken }
$taskUrl = "$BaseUrl/api/v1/agent/boards/$boardId/tasks/$TaskId"
$agentEvidenceUrl = "$BaseUrl/api/v1/agent/boards/$boardId/tasks/$TaskId/evidence-packets"

# Fetch task metadata
try {
    $task = Invoke-RestMethod -Uri $taskUrl -Headers $headers -TimeoutSec 15
}
catch {
    $err = $_.Exception.Response.StatusCode
    throw "Failed to fetch task $TaskId from board ${boardId}: HTTP $err"
}

$requiredArtifactKinds = Normalize-List -Value $task.required_artifact_kinds
$requiredCheckKinds = Normalize-List -Value $task.required_check_kinds

# Determine artifact kind
$ArtifactKind = if ($requiredArtifactKinds.Count -gt 0) {
    "$($requiredArtifactKinds[0])".ToLowerInvariant()
} else {
    'deliverable'
}

# Build display path: use agent name if available, else just the relative path
$relativeArtifactPath = $ArtifactPath.Replace('\','/').TrimStart('./')
$displayPath = if ($agentName) { "$agentName/$relativeArtifactPath" } else { $relativeArtifactPath }

# Build checks array
$checks = @()
if ($CheckKind) {
    $checks += [ordered]@{
        kind = $CheckKind.ToLowerInvariant()
        label = if ($CheckLabel) { $CheckLabel } else { $CheckKind }
        status = $CheckStatus.ToLowerInvariant()
        command = $CheckCommand
        result_summary = $CheckResultSummary
    }
}
elseif ($requiredCheckKinds.Count -eq 1) {
    $requiredKind = "$($requiredCheckKinds[0])".ToLowerInvariant()
    $checks += [ordered]@{
        kind = $requiredKind
        label = $requiredKind
        status = $CheckStatus.ToLowerInvariant()
        command = $null
        result_summary = $null
    }
}

# Build payload
$payload = [ordered]@{
    task_class = if ($task.task_class) { "$($task.task_class)" } else { $null }
    status = 'submitted'
    summary = $Summary
    implementation_delta = $null
    review_notes = $null
    artifacts = @(
        [ordered]@{
            kind = $ArtifactKind.ToLowerInvariant()
            label = "Primary $ArtifactKind artifact"
            workspace_agent_id = $agentId
            workspace_agent_name = $agentName
            workspace_root_key = if ($agentId) { "agent:$agentId" } else { $null }
            relative_path = $relativeArtifactPath
            display_path = $displayPath
            origin_kind = 'original_worker_output'
            is_primary = $true
        }
    )
    checks = $checks
}

$jsonBody = $payload | ConvertTo-Json -Depth 6

if ($Verify) {
    Write-Host "=== VERIFY MODE: Payload would be posted to $agentEvidenceUrl ==="
    Write-Host "=== Headers: X-Agent-Token: $($agentToken.Substring(0, [Math]::Min(20, $agentToken.Length)))... ==="
    Write-Host "=== Payload ==="
    $payload | ConvertTo-Json -Depth 6
    exit 0
}

# Post evidence packet
try {
    $created = Invoke-RestMethod -Method Post -Uri $agentEvidenceUrl -Headers $headers -ContentType 'application/json' -Body $jsonBody -TimeoutSec 20
}
catch {
    $statusCode = $_.Exception.Response.StatusCode
    $msg = $_.Exception.Message
    throw "Evidence submission failed (HTTP $statusCode): $msg. Use your own AUTH_TOKEN from TOOLS.md; admin fallback is disabled."
}

# Output result as compact JSON
$result = [ordered]@{
    task_id = "$($task.id)"
    title = "$($task.title)"
    closure_mode = if ($task.closure_mode) { "$($task.closure_mode)" } else { $null }
    required_artifact_kinds = @($requiredArtifactKinds)
    required_check_kinds = @($requiredCheckKinds)
    created_packet = [ordered]@{
        id = "$($created.id)"
        status = "$($created.status)"
        task_class = if ($created.task_class) { "$($created.task_class)" } else { $null }
        primary_artifact_kind = if ($created.primary_artifact) { "$($created.primary_artifact.kind)" } else { $null }
        primary_artifact_path = if ($created.primary_artifact) { "$($created.primary_artifact.display_path)" } else { $displayPath }
        check_count = @($created.checks).Count
    }
}
$result | ConvertTo-Json -Depth 6 -Compress
