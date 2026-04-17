#!/usr/bin/env pwsh
<# Thin board-specific wrapper for the shared Mission Control assign workflow. #>
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$WorkerAgentId,
    [Parameter(Mandatory = $false)][string]$WorkerWorkspacePath,
    [switch]$BundleOnly,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BoardId = 'dd95369d-1497-41f2-8aeb-e06b51b63162'
$LeadAgentId = "lead-$BoardId"
$WorkspacePath = '/home/cronjev/.openclaw/workspace-lead-dd95369d-1497-41f2-8aeb-e06b51b63162'
$SharedScript = '/home/cronjev/mission-control-tfsmrt/scripts/mc-assign-workflow.ps1'

if (-not (Test-Path -LiteralPath $SharedScript)) {
    throw "Shared script not found: $SharedScript"
}

$params = @{
    BoardId = $BoardId
    LeadWorkspacePath = $WorkspacePath
    LeadAgentId = $LeadAgentId
    TaskId = $TaskId
    WorkerAgentId = $WorkerAgentId
}
if ($WorkerWorkspacePath) {
    $params.WorkerWorkspacePath = $WorkerWorkspacePath
}
if ($BundleOnly) {
    $params.BundleOnly = $true
}
if ($DryRun) {
    $params.DryRun = $true
}

& pwsh -NoProfile -File $SharedScript @params
exit $LASTEXITCODE
