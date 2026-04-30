#!/usr/bin/env pwsh
# verify-preflight.ps1 - Standalone preflight checker for worker agents
# Usage: pwsh -File verify-preflight.ps1 -TaskId <TASK_ID> [-DeliverablesDir <path>]
param(
    [Parameter(Mandatory)][string]$TaskId,
    [string]$DeliverablesDir = $null
)

$ErrorActionPreference = "Stop"

# Resolve deliverables directory
if (-not $DeliverablesDir) {
    $boardId = $env:BOARD_ID
    if (-not $boardId) {
        Write-Error "BOARD_ID env var not set and -DeliverablesDir not provided"
        exit 1
    }
    $DeliverablesDir = "/home/cronjev/.openclaw/workspace-lead-$boardId/tasks/$TaskId/deliverables"
}

$verificationScript = Join-Path $DeliverablesDir "verify-$TaskId.ps1"
if (-not (Test-Path -LiteralPath $verificationScript)) {
    Write-Error "Verification script not found: $verificationScript"
    exit 1
}

# Check runtime signals
$runtimeSignals = @(
    '(?i)\bpytest\b',
    '(?i)\bpython(\d+(\.\d+)*)?\b',
    '(?i)\buv\s+run\b',
    '(?i)\bnode\b',
    '(?i)\bnpm\b',
    '(?i)\bpnpm\b',
    '(?i)\byarn\b',
    '(?i)\bdotnet\b',
    '(?i)\bgo\s+test\b',
    '(?i)\bcargo\s+test\b',
    '(?i)\binvoke-restmethod\b',
    '(?i)\bcurl\b',
    '(?i)\bdocker\b',
    '(?i)\bbash\b',
    '(?i)\bsh\b',
    '(?i)Start-Process',
    '(?i)&\s*\$[A-Za-z_][A-Za-z0-9_]*',
    '(?i)&\s*["''][^"'']+\.(ps1|py|sh|bash|js|ts)',
    '(?i)&\s*pwsh\s+-File',
    '(?i)&\s*powershell\s+-File'
)

$scriptContent = Get-Content -LiteralPath $verificationScript -Raw
$runtimeSignalCount = 0
foreach ($pattern in $runtimeSignals) {
    if ($scriptContent -match $pattern) { $runtimeSignalCount++ }
}

# Check exit paths
$hasSuccessExit = $scriptContent -match '(?mi)^\s*exit\s+0\s*$' -or $scriptContent -match '(?mi)^\s*return\s+0\s*$'
$hasFailureExit = $scriptContent -match '(?mi)^\s*exit\s+1\s*$' -or
    $scriptContent -match '(?mi)^\s*exit\s+\$[A-Za-z_][A-Za-z0-9_]*\s*$' -or
    $scriptContent -match '(?mi)^\s*return\s+1\s*$'

$reasons = @()
$notes = @()

if ($hasSuccessExit -and -not $hasFailureExit) {
    $reasons += 'Verification script contains a success-only exit path.'
}

if ($runtimeSignalCount -eq 0) {
    $reasons += 'No runtime signals detected. Preflight will reject as static-only.'
} else {
    $notes += "Detected runtime signals: $runtimeSignalCount"
}

Write-Host "═══════════════════════════════════════════════════════"
Write-Host "  PREFLIGHT CHECK: $TaskId"
Write-Host "═══════════════════════════════════════════════════════"
Write-Host ""
Write-Host "Verification script: $verificationScript"
Write-Host "Runtime signals found: $runtimeSignalCount"
Write-Host "Success exit path: $hasSuccessExit"
Write-Host "Failure exit path: $hasFailureExit"
Write-Host ""

if ($reasons.Count -gt 0) {
    Write-Host "❌ PREFLIGHT WILL FAIL:" -ForegroundColor Red
    foreach ($r in $reasons) { Write-Host "  - $r" -ForegroundColor Red }
    Write-Host ""
    exit 1
} else {
    Write-Host "✅ PREFLIGHT LOOKS OK" -ForegroundColor Green
    foreach ($n in $notes) { Write-Host "  - $n" }
    Write-Host ""
    exit 0
}
