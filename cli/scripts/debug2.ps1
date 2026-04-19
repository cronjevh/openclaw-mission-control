Write-Host "Test: worker denied task move"
$cmd = "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='workspace-mc-testagent'; & '/home/cronjev/mcon-cli/scripts/mcon.ps1' @('task','move','--task','00000000-0000-0000-0000-000000000001','--status','done')"
Write-Host "CMD: $cmd"
$out = pwsh -NoProfile -Command $cmd 2>&1
Write-Host "`nOutput:"
$out
Write-Host "`nExit: $LASTEXITCODE"
