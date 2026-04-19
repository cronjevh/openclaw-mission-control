#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Live integration test for mcon CLI.
    Dotsources .mcon.env from the project root and exercises all subcommands
    against the live Mission Control API.
.DESCRIPTION
    Loads .mcon.env to set MCON_* env vars, then runs:
      1. task show on a known task
      2. task show on the test fixture task
      3. task comment on the test fixture task (review status)
      4. task move denied for lead role (permission check)
      5. Validation error paths
    Test fixture task is expected to be in review status, assigned to the agent.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$envFile = Join-Path $PSScriptRoot '../.mcon.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    Write-Error ".mcon.env not found at $envFile"
    exit 1
}

Get-Content -LiteralPath $envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.+?)\s*$') {
        [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim('"', "'"), 'Process')
    }
}

Write-Host "Config loaded from .mcon.env:"
Write-Host "  MCON_BASE_URL   = $env:MCON_BASE_URL"
Write-Host "  MCON_BOARD_ID   = $env:MCON_BOARD_ID"
Write-Host "  MCON_AGENT_ID   = $env:MCON_AGENT_ID"
Write-Host "  MCON_AUTH_TOKEN  = $($env:MCON_AUTH_TOKEN.Substring(0,12))..."
Write-Host "  MCON_TEST_TASK  = $env:MCON_TEST_TASK"
Write-Host "  MCON_WSP        = $env:MCON_WSP"
Write-Host ""

$mconScript = Join-Path $PSScriptRoot 'mcon.ps1'
$knownTask = '8fd0c7b1-9392-47ec-bdc6-6e50322b2822'
$testTask = $env:MCON_TEST_TASK
$passCount = 0
$failCount = 0

function Invoke-Mcon {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = pwsh -NoProfile -File $mconScript @Arguments 2>&1
    return @{ exitCode = $LASTEXITCODE; output = ($out -join "`n") }
}

function Assert-Pass {
    param([string]$Label, [hashtable]$Result, [string]$ShouldContain = '')
    if ($Result.exitCode -ne 0) {
        Write-Host "  FAIL: $Label - expected exit 0, got $($Result.exitCode)" -ForegroundColor Red
        Write-Host "        $($Result.output)" -ForegroundColor DarkGray
        $script:failCount++; return
    }
    if ($ShouldContain -and ($Result.output -notmatch [regex]::Escape($ShouldContain))) {
        Write-Host "  FAIL: $Label - output missing '$ShouldContain'" -ForegroundColor Red
        Write-Host "        $($Result.output)" -ForegroundColor DarkGray
        $script:failCount++; return
    }
    Write-Host "  PASS: $Label" -ForegroundColor Green
    $script:passCount++
}

function Assert-Fail {
    param([string]$Label, [hashtable]$Result, [string]$ShouldContain = '')
    if ($Result.exitCode -eq 0) {
        Write-Host "  FAIL: $Label - expected non-zero exit, got 0" -ForegroundColor Red
        Write-Host "        $($Result.output)" -ForegroundColor DarkGray
        $script:failCount++; return
    }
    if ($ShouldContain -and ($Result.output -notmatch [regex]::Escape($ShouldContain))) {
        Write-Host "  FAIL: $Label - output missing '$ShouldContain'" -ForegroundColor Red
        Write-Host "        $($Result.output)" -ForegroundColor DarkGray
        $script:failCount++; return
    }
    Write-Host "  PASS: $Label" -ForegroundColor Green
    $script:passCount++
}

# --- 1. Show known task ---
Write-Host "--- 1. task show (known task) ---"
$r = Invoke-Mcon -Arguments @('task', 'show', '--task', $knownTask)
Assert-Pass -Label "show task $knownTask" -Result $r -ShouldContains $knownTask

# --- 2. Show test fixture task ---
Write-Host "--- 2. task show (test fixture) ---"
$r = Invoke-Mcon -Arguments @('task', 'show', '--task', $testTask)
Assert-Pass -Label 'show test fixture' -Result $r -ShouldContains 'mcon CLI test task'

# --- 3. Comment on test fixture (review status -> lead can comment) ---
Write-Host "--- 3. task comment (on review task) ---"
$r = Invoke-Mcon -Arguments @('task', 'comment', '--task', $testTask, '--message', 'mcon CLI live test with rbac')
Assert-Pass -Label 'comment on review task' -Result $r -ShouldContains 'rbac'

# --- 4. Lead denied task move (permission rule) ---
Write-Host "--- 4. task move denied for lead role ---"
$r = Invoke-Mcon -Arguments @('task', 'move', '--task', $testTask, '--status', 'done')
Assert-Fail -Label 'lead denied task move' -Result $r -ShouldContains 'Permission denied'

# --- 5. Lead denied workflow blocker (worker/verifier only) ---
Write-Host "--- 5. workflow blocker denied for lead role ---"
$r = Invoke-Mcon -Arguments @('workflow', 'blocker', '--task', $testTask, '--message', 'lead live test blocker')
Assert-Fail -Label 'lead denied workflow blocker' -Result $r -ShouldContains 'Permission denied'

# --- 6. Validation: invalid UUID ---
Write-Host "--- 6. validation: invalid task ID ---"
$r = Invoke-Mcon -Arguments @('task', 'show', '--task', 'not-a-uuid')
Assert-Fail -Label 'invalid uuid rejected' -Result $r -ShouldContains 'Invalid task ID'

# --- 7. Validation: invalid status ---
Write-Host "--- 7. validation: invalid status ---"
$r = Invoke-Mcon -Arguments @('task', 'move', '--task', $testTask, '--status', 'flying')
Assert-Fail -Label 'invalid status rejected' -Result $r -ShouldContains 'Invalid status'

# --- 8. Validation: missing --message ---
Write-Host "--- 8. validation: missing --message ---"
$r = Invoke-Mcon -Arguments @('task', 'comment', '--task', $testTask)
Assert-Fail -Label 'missing message rejected' -Result $r -ShouldContains 'required'

# --- 9. Validation: workflow escalate missing --message ---
Write-Host "--- 9. validation: workflow escalate missing --message ---"
$r = Invoke-Mcon -Arguments @('workflow', 'escalate')
Assert-Fail -Label 'workflow escalate missing message rejected' -Result $r -ShouldContains 'required'

Write-Host ""
Write-Host "=== Results: $passCount passed, $failCount failed ==="
if ($failCount -gt 0) { exit 1 }
