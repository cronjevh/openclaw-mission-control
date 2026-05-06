<#
.SYNOPSIS
    Test script for sysadmin script code-review verification flow.
.DESCRIPTION
    Creates test scripts with known issues and validates that the verification
    template correctly identifies them. Also tests a clean script passes.
    Requires pwsh and the verify-sysadmin-template.ps1 to be present.
#>

$ErrorActionPreference = "Stop"
$templatePath = "/home/cronjev/mission-control-tfsmrt/scripts/verify-sysadmin-template.ps1"
if (-not (Test-Path -LiteralPath $templatePath)) {
    Write-Error "Template not found: $templatePath"
    exit 1
}

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "sysadmin-verify-test-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
Write-Host "Test directory: $tmpDir"

# --- Test 1: Script missing required parameters ---
Write-Host "`n=== Test 1: Script missing [switch]`$Check and `$Apply ==="
$badScript = Join-Path $tmpDir "bad-script1.ps1"
@'
# Missing [switch]$Check and [switch]$Apply
param()
Write-Host "Hello"
'@ | Set-Content -LiteralPath $badScript -Encoding UTF8

$badJudgeSpec = Join-Path $tmpDir "evaluate-bad1.json"
@'
{
    "task_summary": "Test script with missing parameters",
    "criteria": {
        "script_contract": "Script must have [switch]$Check and [switch]$Apply parameters"
    },
    "output_schema": {
        "passed": "boolean",
        "reasons": "array of strings"
    },
    "anti_cheat_rules": []
}
'@ | Set-Content -LiteralPath $badJudgeSpec -Encoding UTF8

$evidenceDir = Join-Path $tmpDir "evidence1"
& pwsh -NoProfile -File $templatePath -TaskId "test-bad1" -ScriptPath $badScript -JudgeSpecPath $badJudgeSpec -EvidenceDir $evidenceDir -TimeoutSeconds 10
$resultPath = Join-Path $evidenceDir "validation-result-test-bad1.json"
if (Test-Path -LiteralPath $resultPath) {
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if (-not $result.passed -and $result.static_result.contract_passed -eq $false) {
        Write-Host "PASS: Static check correctly caught missing parameters." -ForegroundColor Green
    } else {
        Write-Host "FAIL: Expected static check to fail." -ForegroundColor Red
    }
} else {
    Write-Host "FAIL: No result file produced." -ForegroundColor Red
}

# --- Test 2: Script with hardcoded secret ---
Write-Host "`n=== Test 2: Script with hardcoded secret ==="
$badScript2 = Join-Path $tmpDir "bad-script2.ps1"
@'
param(
    [switch]$Check,
    [switch]$Apply
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$password = "supersecret123"
Write-Host "Password is $password"
'@ | Set-Content -LiteralPath $badScript2 -Encoding UTF8

$badJudgeSpec2 = Join-Path $tmpDir "evaluate-bad2.json"
@'
{
    "task_summary": "Test script with hardcoded secret",
    "criteria": {
        "no_hardcoded_secrets": "Script must not contain hardcoded passwords or tokens"
    },
    "output_schema": {
        "passed": "boolean",
        "reasons": "array of strings"
    },
    "anti_cheat_rules": []
}
'@ | Set-Content -LiteralPath $badJudgeSpec2 -Encoding UTF8

$evidenceDir2 = Join-Path $tmpDir "evidence2"
& pwsh -NoProfile -File $templatePath -TaskId "test-bad2" -ScriptPath $badScript2 -JudgeSpecPath $badJudgeSpec2 -EvidenceDir $evidenceDir2 -TimeoutSeconds 10
$resultPath2 = Join-Path $evidenceDir2 "validation-result-test-bad2.json"
if (Test-Path -LiteralPath $resultPath2) {
    $result2 = Get-Content -LiteralPath $resultPath2 -Raw | ConvertFrom-Json
    if (-not $result2.passed -and $result2.static_result.safety_passed -eq $false) {
        Write-Host "PASS: Static check correctly caught hardcoded secret." -ForegroundColor Green
    } else {
        Write-Host "FAIL: Expected safety check to fail." -ForegroundColor Red
    }
} else {
    Write-Host "FAIL: No result file produced." -ForegroundColor Red
}

# --- Test 3: Good script that should pass static checks ---
Write-Host "`n=== Test 3: Good script (should pass static checks) ==="
$goodScript = Join-Path $tmpDir "good-script.ps1"
@'
param(
    [switch]$Check,
    [switch]$Apply
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Check) {
    Write-Host "CHECK: Would do something safe"
    exit 0
}
if ($Apply) {
    Write-Host "APPLY: Doing something (simulated)"
    exit 0
}
Write-Host "Usage: $($MyInvocation.MyCommand.Name) [--check|--apply]"
exit 2
'@ | Set-Content -LiteralPath $goodScript -Encoding UTF8

$goodJudgeSpec = Join-Path $tmpDir "evaluate-good.json"
@'
{
    "task_summary": "Test script that is well-formed",
    "criteria": {
        "script_contract": "Script must have proper contract",
        "safety": "Script must be safe"
    },
    "output_schema": {
        "passed": "boolean",
        "reasons": "array of strings"
    },
    "anti_cheat_rules": []
}
'@ | Set-Content -LiteralPath $goodJudgeSpec -Encoding UTF8

$evidenceDir3 = Join-Path $tmpDir "evidence3"
& pwsh -NoProfile -File $templatePath -TaskId "test-good" -ScriptPath $goodScript -JudgeSpecPath $goodJudgeSpec -EvidenceDir $evidenceDir3 -TimeoutSeconds 10
$resultPath3 = Join-Path $evidenceDir3 "validation-result-test-good.json"
if (Test-Path -LiteralPath $resultPath3) {
    $result3 = Get-Content -LiteralPath $resultPath3 -Raw | ConvertFrom-Json
    if ($result3.static_result.overall_passed -eq $true) {
        Write-Host "PASS: Static checks passed for good script." -ForegroundColor Green
    } else {
        Write-Host "FAIL: Static checks should have passed." -ForegroundColor Red
    }
} else {
    Write-Host "FAIL: No result file produced." -ForegroundColor Red
}

# Cleanup option
Write-Host "`nTest directory preserved at: $tmpDir"
Write-Host "To clean up, run: Remove-Item -LiteralPath '$tmpDir' -Recurse -Force"
