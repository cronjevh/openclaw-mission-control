$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "Running permission test in-process..."

$out = & "$PSScriptRoot/run-mcon.ps1" -BaseURL 'http://localhost:9999' -Token 'test-token-placeholder' -BoardID '00000000-0000-0000-0000-000000000000' -WSP 'workspace-mc-testagent' -Args @('task','move','--task','00000000-0000-0000-0000-000000000001','--status','done') 2>&1
Write-Host "Exit code: $LASTEXITCODE"
Write-Host "Output:"
$out | Write-Host
