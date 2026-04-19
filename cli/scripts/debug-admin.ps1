# Test: worker denied admin.gettokens
Write-Host '--- worker denied admin.gettokens ---'
$out = pwsh -NoProfile -Command "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='workspace-mc-testagent'; & '/home/cronjev/mcon-cli/scripts/mcon.ps1' admin gettokens" 2>&1
Write-Host "Exit: $LASTEXITCODE"
Write-Host "Output:`n$out"
Write-Host ''

# Test: lead denied admin.gettokens
Write-Host '--- lead denied admin.gettokens ---'
$out = pwsh -NoProfile -Command "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='workspace-lead-testboard'; & '/home/cronjev/mcon-cli/scripts/mcon.ps1' admin gettokens" 2>&1
Write-Host "Exit: $LASTEXITCODE"
Write-Host "Output:`n$out"
Write-Host ''

# Test: gateway missing LOCAL_AUTH_TOKEN
Write-Host '--- gateway missing LOCAL_AUTH_TOKEN ---'
$out = pwsh -NoProfile -Command "`$env:MCON_BASE_URL='http://localhost:9999'; `$env:MCON_AUTH_TOKEN='test-token-placeholder'; `$env:MCON_BOARD_ID='00000000-0000-0000-0000-000000000000'; `$env:MCON_WSP='workspace-gateway-testgw'; & '/home/cronjev/mcon-cli/scripts/mcon.ps1' admin gettokens" 2>&1
Write-Host "Exit: $LASTEXITCODE"
Write-Host "Output:`n$out"
