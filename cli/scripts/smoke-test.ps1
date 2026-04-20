#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Smoke tests for mcon CLI. Validates argument parsing and error handling.
.DESCRIPTION
    These tests exercise the CLI surface without requiring a live API.
    They verify: usage errors, validation errors, help output.
    For live API tests, set MCON_BASE_URL, MCON_AUTH_TOKEN, MCON_BOARD_ID.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Set dummy env to avoid keybag loading and allow validation tests
$env:MCON_AUTH_TOKEN = 'dummy'
$env:MCON_BASE_URL = 'http://localhost:9999'
$env:MCON_BOARD_ID = '00000000-0000-0000-0000-000000000000'
$env:MCON_WSP = 'workspace-gateway-test'

$mconScript = Join-Path $PSScriptRoot 'mcon.ps1'
$passCount = 0
$failCount = 0

function Assert-ExitCode {
    param(
        [string]$Label,
        [int]$Expected,
        [int]$Actual
    )
    if ($Expected -eq $Actual) {
        $script:passCount++
    } else {
        Write-Host "FAIL: $Label - expected exit $Expected, got $Actual"
        $script:failCount++
    }
}

function Assert-OutputContains {
    param(
        [string]$Label,
        [string]$Output,
        [string]$Expected
    )
    if ($Output -match [regex]::Escape($Expected)) {
        $script:passCount++
    } else {
        Write-Host "FAIL: $Label - expected output to contain '$Expected'"
        $script:failCount++
    }
}

Write-Host '=== mcon smoke tests ==='
Write-Host ''

# Test: no args -> usage error
$out = pwsh -NoProfile -File $mconScript 2>&1
Assert-ExitCode -Label 'no-args-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'no-args-json' -Output ($out -join '') -Expected '"ok":false'

# Test: unknown subcommand
$out = pwsh -NoProfile -File $mconScript foo 2>&1
Assert-ExitCode -Label 'unknown-cmd-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'unknown-cmd-error' -Output ($out -join '') -Expected 'Unknown subcommand'

# Test: help
$out = pwsh -NoProfile -File $mconScript help 2>&1
Assert-ExitCode -Label 'help-exit0' -Expected 0 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'help-content' -Output ($out -join '') -Expected 'task show'

# Test: task without action
$out = pwsh -NoProfile -File $mconScript task 2>&1
Assert-ExitCode -Label 'task-no-action-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'task-no-action-error' -Output ($out -join '') -Expected 'task <action>'

# Test: task show without selector
$out = pwsh -NoProfile -File $mconScript task show 2>&1
Assert-ExitCode -Label 'show-no-task-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'show-no-task-error' -Output ($out -join '') -Expected 'requires either'

# Test: task show with invalid UUID
$out = pwsh -NoProfile -File $mconScript task show --task not-a-uuid 2>&1
Assert-ExitCode -Label 'show-bad-uuid-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'show-bad-uuid-error' -Output ($out -join '') -Expected 'Invalid task ID'

# Test: task show with both --task and --tags
$out = pwsh -NoProfile -File $mconScript task show --task 00000000-0000-0000-0000-000000000001 --tags project-mission-control-mechanics 2>&1
Assert-ExitCode -Label 'show-task-and-tags-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'show-task-and-tags-error' -Output ($out -join '') -Expected 'either --task'

# Test: task show with tags reaches API layer
$out = pwsh -NoProfile -File $mconScript task show --tags project-mission-control-mechanics 2>&1
Assert-ExitCode -Label 'show-tags-api-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'show-tags-api-error' -Output ($out -join '') -Expected 'api_error'

# Test: task comment without --message
$out = pwsh -NoProfile -File $mconScript task comment --task 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'comment-no-msg-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'comment-no-msg-error' -Output ($out -join '') -Expected 'required'

# Test: task move without --status
$out = pwsh -NoProfile -File $mconScript task move --task 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'move-no-status-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'move-no-status-error' -Output ($out -join '') -Expected 'required'

# Test: task move with invalid status
$out = pwsh -NoProfile -File $mconScript task move --task 00000000-0000-0000-0000-000000000001 --status flying 2>&1
Assert-ExitCode -Label 'move-bad-status-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'move-bad-status-error' -Output ($out -join '') -Expected 'Invalid status'

# Test: unknown flag
$out = pwsh -NoProfile -File $mconScript task show --task 00000000-0000-0000-0000-000000000001 --bogus 2>&1
Assert-ExitCode -Label 'unknown-flag-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'unknown-flag-error' -Output ($out -join '') -Expected 'Unknown flag'

# Test: verify without action
$out = pwsh -NoProfile -File $mconScript verify 2>&1
Assert-ExitCode -Label 'verify-no-action-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'verify-no-action-error' -Output ($out -join '') -Expected 'verify <action>'

# Test: verify run without --task
$out = pwsh -NoProfile -File $mconScript verify run 2>&1
Assert-ExitCode -Label 'verify-run-no-task-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'verify-run-no-task-error' -Output ($out -join '') -Expected 'required'

# Test: workflow blocker without --task
$out = pwsh -NoProfile -File $mconScript workflow blocker --message blocked 2>&1
Assert-ExitCode -Label 'blocker-no-task-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'blocker-no-task-error' -Output ($out -join '') -Expected 'required'

# Test: workflow blocker without --message
$out = pwsh -NoProfile -File $mconScript workflow blocker --task 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'blocker-no-message-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'blocker-no-message-error' -Output ($out -join '') -Expected 'required'

# Test: workflow escalate without --message
$out = pwsh -NoProfile -File $mconScript workflow escalate 2>&1
Assert-ExitCode -Label 'escalate-no-message-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'escalate-no-message-error' -Output ($out -join '') -Expected 'required'

# Test: workflow escalate with target agent but no secret key
$out = pwsh -NoProfile -File $mconScript workflow escalate --message blocked --target-agent 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'escalate-target-without-secret-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'escalate-target-without-secret-error' -Output ($out -join '') -Expected 'require --secret-key'

# Test: workflow escalate with channel and secret key
$out = pwsh -NoProfile -File $mconScript workflow escalate --message blocked --secret-key GITHUB_TOKEN --channel chat 2>&1
Assert-ExitCode -Label 'escalate-secret-with-channel-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'escalate-secret-with-channel-error' -Output ($out -join '') -Expected 'only valid'

# Test: task create with invalid tag ID
$out = pwsh -NoProfile -File $mconScript task create --title 'test' --tags not-a-uuid 2>&1
Assert-ExitCode -Label 'create-bad-tag-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'create-bad-tag-error' -Output ($out -join '') -Expected 'Invalid tag ID'

# Test: task create with invalid depends-on ID
$out = pwsh -NoProfile -File $mconScript task create --title 'test' --depends-on not-a-uuid 2>&1
Assert-ExitCode -Label 'create-bad-dep-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'create-bad-dep-error' -Output ($out -join '') -Expected 'Invalid depends-on task ID'

# Test: task create with valid tags and depends-on (passes validation, fails at API)
$out = pwsh -NoProfile -File $mconScript task create --title 'test' --tags 11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222 --depends-on 33333333-3333-3333-3333-333333333333 2>&1
Assert-ExitCode -Label 'create-valid-tags-deps-api-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'create-valid-tags-deps-api-error' -Output ($out -join '') -Expected 'api_error'

# Test: task update without --task
$out = pwsh -NoProfile -File $mconScript task update --title 'new' 2>&1
Assert-ExitCode -Label 'update-no-task-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-no-task-error' -Output ($out -join '') -Expected 'required'

# Test: task update without any update fields
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 2>&1
Assert-ExitCode -Label 'update-no-fields-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-no-fields-error' -Output ($out -join '') -Expected 'At least one update field'

# Test: task update with invalid tag ID
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 --tags bad-uuid 2>&1
Assert-ExitCode -Label 'update-bad-tag-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-bad-tag-error' -Output ($out -join '') -Expected 'Invalid tag ID'

# Test: task update with invalid depends-on ID
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 --depends-on bad-uuid 2>&1
Assert-ExitCode -Label 'update-bad-dep-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-bad-dep-error' -Output ($out -join '') -Expected 'Invalid depends-on task ID'

# Test: task update with valid fields (passes validation, fails at API)
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 --title 'new' --priority high 2>&1
Assert-ExitCode -Label 'update-valid-api-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-valid-api-error' -Output ($out -join '') -Expected 'api_error'

# Test: task update with --backlog invalid value
$out = pwsh -NoProfile -File $mconScript task update --task 00000000-0000-0000-0000-000000000001 --backlog maybe 2>&1
Assert-ExitCode -Label 'update-bad-backlog-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'update-bad-backlog-error' -Output ($out -join '') -Expected "must be 'true' or 'false'"

# Test: admin cron without --board-id
$out = pwsh -NoProfile -File $mconScript admin cron --cadence-minutes 10 2>&1
Assert-ExitCode -Label 'cron-no-board-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'cron-no-board-error' -Output ($out -join '') -Expected '--board-id'

# Test: admin cron without --cadence-minutes
$out = pwsh -NoProfile -File $mconScript admin cron --board-id 00000000-0000-0000-0000-000000000000 2>&1
Assert-ExitCode -Label 'cron-no-cadence-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'cron-no-cadence-error' -Output ($out -join '') -Expected '--cadence-minutes'

# Test: admin cron with invalid board-id
$out = pwsh -NoProfile -File $mconScript admin cron --board-id not-a-uuid --cadence-minutes 10 2>&1
Assert-ExitCode -Label 'cron-bad-board-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'cron-bad-board-error' -Output ($out -join '') -Expected 'Invalid board ID'

# Test: admin cron with non-integer cadence
$out = pwsh -NoProfile -File $mconScript admin cron --board-id 00000000-0000-0000-0000-000000000000 --cadence-minutes abc 2>&1
Assert-ExitCode -Label 'cron-bad-cadence-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'cron-bad-cadence-error' -Output ($out -join '') -Expected 'must be an integer'

Write-Host ''
Write-Host "Results: $passCount passed, $failCount failed"

if ($failCount -gt 0) {
    exit 1
}
Write-Host 'All smoke tests passed.'

# --- Permission tests (require env vars) ---
Write-Host ''
Write-Host '=== mcon permission smoke tests ==='
Write-Host ''

# Helper function to run mcon with explicit env in a new process
function Invoke-MconProcess {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$Wsp = 'workspace-gateway-testgw'
    )
    $argString = $Arguments -join ' '
    $cmd = "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='$Wsp'; & '$mconScript' $argString"
    $out = pwsh -NoProfile -Command $cmd 2>&1
    return $out
}

# Test: worker denied task move
Write-Host '--- worker denied task move ---'
$out = Invoke-MconProcess -Arguments @('task','move','--task','00000000-0000-0000-0000-000000000001','--status','done') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-move-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-move-denied-msg' -Output $out -Expected 'Permission denied'

# Test: lead denied task move
Write-Host '--- lead denied task move ---'
$out = Invoke-MconProcess -Arguments @('task','move','--task','00000000-0000-0000-0000-000000000001','--status','done') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-move-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-move-denied-msg' -Output $out -Expected 'Permission denied'

# Test: gateway allowed task move (will fail at API but not at permission)
Write-Host '--- gateway passes permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('task','move','--task','00000000-0000-0000-0000-000000000001','--status','done') -Wsp 'workspace-gateway-testgw'
Assert-ExitCode -Label 'gateway-move-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'gateway-move-passes-perm' -Output $out -Expected 'Connection refused'

# Test: worker denied verify run
Write-Host '--- worker denied verify run ---'
$out = Invoke-MconProcess -Arguments @('verify','run','--task','00000000-0000-0000-0000-000000000001') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-verify-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-verify-denied-msg' -Output $out -Expected 'Permission denied'

# Test: worker allowed workflow blocker (will fail at API but not at permission)
Write-Host '--- worker passes workflow blocker permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('workflow','blocker','--task','00000000-0000-0000-0000-000000000001','--message','stuck') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-blocker-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-blocker-passes-perm' -Output $out -Expected 'Connection refused'

# Test: lead denied workflow blocker
Write-Host '--- lead denied workflow blocker ---'
$out = Invoke-MconProcess -Arguments @('workflow','blocker','--task','00000000-0000-0000-0000-000000000001','--message','needhelp') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-blocker-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-blocker-denied-msg' -Output $out -Expected 'Permission denied'

# Test: worker denied workflow escalate
Write-Host '--- worker denied workflow escalate ---'
$out = Invoke-MconProcess -Arguments @('workflow','escalate','--message','needhelp') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-escalate-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-escalate-denied-msg' -Output $out -Expected 'Permission denied'

# Test: lead allowed workflow escalate (API fails after permission)
Write-Host '--- lead passes workflow escalate permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('workflow','escalate','--message','needhelp') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-escalate-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-escalate-passes-perm' -Output $out -Expected 'Connection refused'

# Test: worker denied task update
Write-Host '--- worker denied task update ---'
$out = Invoke-MconProcess -Arguments @('task','update','--task','00000000-0000-0000-0000-000000000001','--title','new') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-update-denied-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-update-denied-msg' -Output $out -Expected 'Permission denied'

# Test: lead allowed task update (API fails after permission)
Write-Host '--- lead passes task update permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('task','update','--task','00000000-0000-0000-0000-000000000001','--title','new') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-update-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-update-passes-perm' -Output $out -Expected 'Connection refused'

# Test: gateway allowed task update (API fails after permission)
Write-Host '--- gateway passes task update permission check (API fails) ---'
$out = Invoke-MconProcess -Arguments @('task','update','--task','00000000-0000-0000-0000-000000000001','--title','new') -Wsp 'workspace-gateway-testgw'
Assert-ExitCode -Label 'gateway-update-api-error-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'gateway-update-passes-perm' -Output $out -Expected 'Connection refused'

# Test: missing MCON_WSP
Write-Host '--- missing MCON_WSP error ---'
$out = pwsh -NoProfile -Command "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; remove-item env:MCON_WSP -ErrorAction SilentlyContinue; & '/home/cronjev/mcon-cli/scripts/mcon.ps1' task show --task 00000000-0000-0000-0000-000000000001" 2>&1
Assert-ExitCode -Label 'missing-wsp-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'missing-wsp-error' -Output $out -Expected 'MCON_WSP'

# Test: unrecognized MCON_WSP prefix
Write-Host '--- unrecognized MCON_WSP prefix ---'
$out = pwsh -NoProfile -Command "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='workspace-unknown-foo'; & '/home/cronjev/mcon-cli/scripts/mcon.ps1' task show --task 00000000-0000-0000-0000-000000000001" 2>&1
Assert-ExitCode -Label 'bad-wsp-exit1' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'bad-wsp-error' -Output $out -Expected 'Cannot determine role'

# --- admin.gettokens permission tests ---
Write-Host ''
Write-Host '--- admin.gettokens permission tests ---'

# Test: worker denied admin.gettokens
Write-Host '--- worker denied admin.gettokens ---'
$out = Invoke-MconProcess -Arguments @('admin','gettokens') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-admin-deny' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-admin-msg' -Output $out -Expected 'Permission denied'

# Test: lead denied admin.gettokens
Write-Host '--- lead denied admin.gettokens ---'
$out = Invoke-MconProcess -Arguments @('admin','gettokens') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-admin-deny' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-admin-msg' -Output $out -Expected 'Permission denied'

# Test: gateway admin.gettokens allowed but fails at API call (no server)
Write-Host '--- gateway admin.gettokens allowed (API connection refused) ---'
$out = Invoke-MconProcess -Arguments @('admin','gettokens') -Wsp 'workspace-gateway-testgw'
Assert-ExitCode -Label 'gateway-admin-api-fail' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'gateway-admin-api-fail-msg' -Output $out -Expected 'Connection refused'

# --- admin.cron permission tests ---
Write-Host ''
Write-Host '--- admin.cron permission tests ---'

# Test: worker denied admin.cron
Write-Host '--- worker denied admin.cron ---'
$out = Invoke-MconProcess -Arguments @('admin','cron','--board-id','00000000-0000-0000-0000-000000000000','--cadence-minutes','10') -Wsp 'workspace-mc-testagent'
Assert-ExitCode -Label 'worker-cron-deny' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'worker-cron-msg' -Output $out -Expected 'Permission denied'

# Test: lead denied admin.cron
Write-Host '--- lead denied admin.cron ---'
$out = Invoke-MconProcess -Arguments @('admin','cron','--board-id','00000000-0000-0000-0000-000000000000','--cadence-minutes','10') -Wsp 'workspace-lead-testboard'
Assert-ExitCode -Label 'lead-cron-deny' -Expected 1 -Actual $LASTEXITCODE
Assert-OutputContains -Label 'lead-cron-msg' -Output $out -Expected 'Permission denied'

Write-Host ''
Write-Host "Permission smoke results: $passCount passed, $failCount failed (total)"

if ($failCount -gt 0) {
    exit 1
}
Write-Host 'All smoke tests passed.'
