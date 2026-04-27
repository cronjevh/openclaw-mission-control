function Sync-MconAllowAgents {
    <#
    .SYNOPSIS
        Synchronizes lead agent allowAgents lists in openclaw.json with current board assignments from the keybag.
    .DESCRIPTION
        Reads the agent token keybag to determine which workers belong to each board.
        For each lead agent in openclaw.json, sets subagents.allowAgents to include all workers on that board.
        This ensures leads can spawn workers on their board.
    .EXAMPLE
        Sync-MconAllowAgents
    #>

    # Resolve paths
    $scriptDir = Split-Path $PSScriptRoot -Parent
    $keybagEnc = Join-Path $scriptDir '.agent-tokens.json.enc'
    $keybagPlain = Join-Path $scriptDir '.agent-tokens.json'
    $openclawRoot = $env:OPENCLAW_ROOT ?? $HOME
    if ($openclawRoot -notlike '*/openclaw') {
        $openclawRoot = Join-Path $openclawRoot '.openclaw'
    }
    $openclawConfig = Join-Path $openclawRoot 'openclaw.json'
    $secretKey = Join-Path $HOME '.mcon-secret.key'

    # Decrypt keybag
    if (-not (Test-Path $secretKey)) {
        throw "Secret key not found at $secretKey"
    }
    if (-not (Test-Path $keybagEnc)) {
        throw "Encrypted keybag not found at $keybagEnc"
    }
    $encContent = Get-Content -LiteralPath $keybagEnc -Raw
    $key = Get-Content -Path $secretKey -AsByteStream
    $secureString = ConvertTo-SecureString -String $encContent -Key $key
    $bstrPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    $jsonContent = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrPtr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrPtr)
    $keybag = $jsonContent | ConvertFrom-Json

    $agents = $keybag.agents

    # Build board -> workers (spawn IDs: mc-<uuid>) and board -> leads (spawn IDs: lead-<board_id>)
    $boardWorkers = @{}
    $boardLeads = @{}
    foreach ($aid in $agents.PSObject.Properties.Name) {
        $agent = $agents.$aid
        $boardId = $agent.board_id
        if (-not $boardId) { continue }

        if ($agent.is_board_lead) {
            $spawnId = "lead-$boardId"
            $boardLeads[$boardId] = $spawnId
        } else {
            $spawnId = "mc-$aid"
            if (-not $boardWorkers.ContainsKey($boardId)) {
                $boardWorkers[$boardId] = @()
            }
            $boardWorkers[$boardId] += $spawnId
        }
    }

    # Load openclaw.json
    if (-not (Test-Path $openclawConfig)) {
        throw "openclaw.json not found at $openclawConfig"
    }
    $oc = Get-Content -LiteralPath $openclawConfig -Raw | ConvertFrom-Json -Depth 10
    $ocAgents = $oc.agents.list

    $updated = 0
    foreach ($leadOc in $ocAgents) {
        $leadId = $leadOc.id
        if ($leadId -notlike 'lead-*') { continue }

        # Extract board ID from leadId (format: lead-<board_id>)
        $boardId = $leadId.Substring(5)  # remove 'lead-'

        $workersOnBoard = $boardWorkers[$boardId]
        if (-not $workersOnBoard -or $workersOnBoard.Count -eq 0) {
            # No workers on this board; set to empty array
            $leadOc.subagents.allowAgents = @()
            continue
        }

        # Set allowAgents to exactly the workers on this board (unique, sorted)
        $newAllow = $workersOnBoard | Sort-Object -Unique

        $currentAllow = $leadOc.subagents.allowAgents
        if (-not $currentAllow) { $currentAllow = @() }

        if ($newAllow.Count -ne $currentAllow.Count -or ($newAllow -ne $currentAllow)) {
            $leadOc.subagents.allowAgents = $newAllow
            $updated++
            Write-Host "Updated $leadId (board $boardId): $($newAllow.Count) workers"
        } else {
            Write-Host "$leadId already up-to-date ($($newAllow.Count) workers)"
        }
    }

    if ($updated -gt 0) {
        $oc.agents.list = $ocAgents
        $oc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $openclawConfig -Encoding UTF8
        Write-Host "Sync complete. Updated $updated lead agent(s)."
    } else {
        Write-Host "Sync complete. No changes needed."
    }
}

Export-ModuleMember -Function Sync-MconAllowAgents
