function Get-MconBoardAgentsOrdered {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId
    )

    $encodedBoardId = [uri]::EscapeDataString($BoardId)
    $rosterUri = "$BaseUrl/api/v1/agent/agents?board_id=$encodedBoardId&limit=100"
    $rosterResponse = Invoke-MconApi -Method Get -Uri $rosterUri -Token $Token
    $agents = @(Get-MconResponseItems -Response $rosterResponse)

    $lead = $null
    $verifiers = @()
    $workers = @()

    foreach ($agent in $agents) {
        if ($null -eq $agent) { continue }
        if ($agent.is_gateway_main) { continue }

        $role = $null
        if ($agent.identity_profile -and $agent.identity_profile.PSObject.Properties.Name -contains 'role') {
            $role = [string]$agent.identity_profile.role
        } elseif ($agent.PSObject.Properties.Name -contains 'role') {
            $role = [string]$agent.role
        }

        if ($agent.is_board_lead) {
            $lead = $agent
            continue
        }

        if ($role -and $role.Trim() -match 'verifier') {
            $verifiers += $agent
            continue
        }

        $workers += $agent
    }

    $ordered = @()
    if ($lead) {
        $ordered += $lead
    }
    foreach ($w in $workers) {
        $ordered += $w
    }
    foreach ($v in $verifiers) {
        $ordered += $v
    }

    return $ordered
}

function Invoke-MconDispatchBoard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$DelaySeconds = 60,
        [int]$ChatLimit = 20
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id

    $orderedAgents = Get-MconBoardAgentsOrdered -BaseUrl $baseUrl -Token $authToken -BoardId $boardId

    if ($orderedAgents.Count -eq 0) {
        return [ordered]@{
            ok     = $true
            action = 'workflow.dispatchboard'
            board  = $boardId
            status = 'no_agents'
            agents = @()
            results = @()
        }
    }

    $keybag = $null
    try {
        $keybag = Get-MconDecryptedKeybag
    } catch {
        Write-Warning ("[{0}] could not decrypt keybag: {1}" -f (Get-Date).ToString('o'), $_.Exception.Message)
    }

    $results = @()
    $agentSummaries = @()

    for ($idx = 0; $idx -lt $orderedAgents.Count; $idx++) {
        $agent = $orderedAgents[$idx]
        $agentId = $agent.id
        $agentName = if ($agent.PSObject.Properties.Name -contains 'name') { $agent.name } else { $agentId }
        $isLead = [bool]$agent.is_board_lead

        $role = 'worker'
        if ($isLead) {
            $role = 'lead'
        } else {
            $idRole = $null
            if ($agent.identity_profile -and $agent.identity_profile.PSObject.Properties.Name -contains 'role') {
                $idRole = [string]$agent.identity_profile.role
            } elseif ($agent.PSObject.Properties.Name -contains 'role') {
                $idRole = [string]$agent.role
            }
            if ($idRole -and $idRole.Trim() -match 'verifier') {
                $role = 'verifier'
            }
        }

        $wsp = if ($isLead) {
            "workspace-lead-$($agent.board_id)"
        } else {
            "workspace-mc-$($agent.id)"
        }

        $workspacePath = Join-Path '/home/cronjev/.openclaw' $wsp

        Write-Host ("[{0}] [{1}/{2}] dispatching {3} (role={4}, agent={5})" -f `
            (Get-Date).ToString('o'), ($idx + 1), $orderedAgents.Count, $agentName, $role, $agentId)

        $originalLocation = Get-Location

        $agentResult = $null
        try {
            Set-Location -LiteralPath $workspacePath

            $agentConfig = $null
            if ($keybag) {
                foreach ($aid in $keybag.agents.PSObject.Properties.Name) {
                    $kbAgent = $keybag.agents.$aid
                    if ($kbAgent.workspace_path -eq $workspacePath) {
                        $agentConfig = [ordered]@{
                            base_url       = if ($keybag.base_url) { $keybag.base_url } else { 'http://localhost:8002' }
                            auth_token     = $kbAgent.token
                            board_id       = $kbAgent.board_id
                            agent_id       = $kbAgent.id
                            wsp            = (Split-Path $kbAgent.workspace_path -Leaf)
                            workspace_path = $kbAgent.workspace_path
                        }
                        break
                    }
                }
            }

            if (-not $agentConfig) {
                throw "No agent configuration found in keybag for workspace: $workspacePath"
            }

            $dispatchResult = Invoke-MconDispatch -Config $agentConfig -ChatLimit $chatLimit

            $invocationAgent = if ($role -eq 'lead') { "lead-$boardId" } else { "mc-$agentId" }

            $queueInfo = [ordered]@{
                queued             = 0
                skipped            = 0
                retired            = @()
                processing_started = $false
            }
            if ($dispatchResult.act -eq $true) {
                $dispatchStates = @(Get-MconHeartbeatDispatchStates -DispatchResult $dispatchResult)
                foreach ($ds in $dispatchStates) {
                    $addResult = Add-MconHeartbeatQueueItem -WorkspacePath $workspacePath -InvocationAgent $invocationAgent -DispatchState $ds
                    switch ($addResult) {
                        'queued' {
                            $queueInfo.queued++
                            break
                        }
                        'retired' {
                            $queueInfo.skipped++
                            $taskId = Get-MconHeartbeatQueueItemId -DispatchState $ds
                            $queueInfo.retired += $taskId
                            break
                        }
                        default {
                            $queueInfo.skipped++
                            break
                        }
                    }
                }
            }

            $queueInfo.processing_started = Start-MconHeartbeatQueueProcessor -WorkspacePath $workspacePath -MconScriptPath $PSCommandPath

            $agentResult = [ordered]@{
                agent_id   = $agentId
                agent_name = $agentName
                role       = $role
                dispatch   = $dispatchResult
                queue      = $queueInfo
                error      = $null
            }
        } catch {
            $errMsg = $_.Exception.Message
            Write-Warning ("[{0}] dispatch failed for {1}: {2}" -f (Get-Date).ToString('o'), $agentName, $errMsg)
            $agentResult = [ordered]@{
                agent_id   = $agentId
                agent_name = $agentName
                role       = $role
                dispatch   = $null
                queue      = $null
                error      = $errMsg
            }
        } finally {
            Set-Location -LiteralPath $originalLocation
        }

        $results += $agentResult
        $agentSummaries += [ordered]@{
            agent_id   = $agentId
            agent_name = $agentName
            role       = $role
            act        = if ($agentResult.dispatch) { $agentResult.dispatch.act } else { $false }
            reason     = if ($agentResult.dispatch) { $agentResult.dispatch.reason } else { 'error' }
            error      = $agentResult.error
        }

        if ($idx -lt ($orderedAgents.Count - 1) -and $DelaySeconds -gt 0) {
            Write-Host ("[{0}] waiting {1}s before next agent..." -f (Get-Date).ToString('o'), $DelaySeconds)
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return [ordered]@{
        ok       = $true
        action   = 'workflow.dispatchboard'
        board_id = $boardId
        agents   = $agentSummaries
        results  = $results
    }
}

Export-ModuleMember -Function Get-MconBoardAgentsOrdered, Invoke-MconDispatchBoard
