function Read-MconToolsMd {
    param([Parameter(Mandatory)][string]$Path)
    $map = @{}
    $content = Get-Content -LiteralPath $Path -Raw
    foreach ($line in $content -split "`n") {
        if ($line -match '^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.+?)\s*$') {
            $map[$matches[1]] = $matches[2].Trim('"', "'", '`')
        }
    }
    return $map
}

function Get-StableAgentToken {
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$LocalAuthToken
    )
    $message = [Text.Encoding]::UTF8.GetBytes("mission-control-agent-token:v1:$AgentId")
    $key = [Text.Encoding]::UTF8.GetBytes($LocalAuthToken.Trim())
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    try {
        $digest = $hmac.ComputeHash($message)
    } finally {
        $hmac.Dispose()
    }
    $base64 = [Convert]::ToBase64String($digest).TrimEnd('=')
    $base64 = $base64.Replace('+', '-').Replace('/', '_')
    return "mca_$base64"
}

function Get-AgentWorkspacePath {
    param(
        [Parameter(Mandatory)]$AgentDetail
    )

    $workspaceRoot = '/home/cronjev/.openclaw'

    if ($AgentDetail.PSObject.Properties["is_gateway_main"] -and [bool]$AgentDetail.is_gateway_main) {
        if ($AgentDetail.PSObject.Properties["gateway_id"] -and $AgentDetail.gateway_id) {
            return Join-Path $workspaceRoot ("workspace-gateway-" + $AgentDetail.gateway_id)
        }
    } elseif ($AgentDetail.PSObject.Properties["is_board_lead"] -and [bool]$AgentDetail.is_board_lead) {
        if ($AgentDetail.PSObject.Properties["board_id"] -and $AgentDetail.board_id) {
            return Join-Path $workspaceRoot ("workspace-lead-" + $AgentDetail.board_id)
        }
    } else {
        if ($AgentDetail.PSObject.Properties["id"] -and $AgentDetail.id) {
            return Join-Path $workspaceRoot ("workspace-mc-" + $AgentDetail.id)
        }
    }

    return $null
}

function Invoke-MconAdminGetTokens {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Wsp)

    $gatewayWorkspace = Join-Path '/home/cronjev/.openclaw' $Wsp
    if (-not (Test-Path -LiteralPath $gatewayWorkspace)) {
        $gatewayWorkspace = Join-Path $env:HOME '.openclaw' $config.wsp
    }

    $toolsPath = Join-Path $gatewayWorkspace 'TOOLS.md'
    $localAuthToken = $null
    if (Test-Path -LiteralPath $toolsPath) {
        $toolsMap = Read-MconToolsMd -Path $toolsPath
        if ($toolsMap.ContainsKey('LOCAL_AUTH_TOKEN')) {
            $localAuthToken = $toolsMap['LOCAL_AUTH_TOKEN']
        }
    }

    if (-not $localAuthToken) {
        $backendEnvPath = '/home/cronjev/mission-control-tfsmrt/.env'
        if (Test-Path -LiteralPath $backendEnvPath) {
            $envMap = Read-MconToolsMd -Path $backendEnvPath
            if ($envMap.ContainsKey('LOCAL_AUTH_TOKEN')) {
                $localAuthToken = $envMap['LOCAL_AUTH_TOKEN']
            }
        }
    }

    if (-not $localAuthToken) {
        throw "LOCAL_AUTH_TOKEN not found. Set it in your gateway TOOLS.md or in backend .env."
    }

    $baseUrl = 'http://localhost:8002'
    $headers = @{
        Authorization = "Bearer $localAuthToken"
        Accept        = 'application/json'
    }

    $agentsUri = "$baseUrl/api/v1/agents?limit=200"
    try {
        $agentsResponse = Invoke-RestMethod -Method Get -Uri $agentsUri -Headers $headers -TimeoutSec 20
    }
    catch {
        throw "Failed to fetch agents from $agentsUri : $($_.Exception.Message)"
    }

    $agentsList = @()
    if ($agentsResponse.PSObject.Properties.Name -contains 'items') {
        $agentsList = @($agentsResponse.items)
    } elseif ($agentsResponse.PSObject.Properties.Name -contains 'agents') {
        $agentsList = @($agentsResponse.agents)
    } elseif ($agentsResponse -is [System.Collections.IEnumerable] -and $agentsResponse -isnot [string]) {
        $agentsList = @($agentsResponse)
    } else {
        throw "Unexpected agents list response shape"
    }

    $bag = [ordered]@{
        version       = '1.0'
        generated_at  = [DateTime]::UtcNow.ToString('o')
        base_url      = $baseUrl
        agents        = @{}
    }

    foreach ($agent in $agentsList) {
        $agentId = $null
        foreach ($prop in @('id', 'agent_id', 'agentId')) {
            if ($agent.PSObject.Properties.Name -contains $prop) {
                $agentId = [string]$agent.$prop
                break
            }
        }
        if (-not $agentId) { continue }

        $agentName = if ($agent.PSObject.Properties.Name -contains 'name') { [string]$agent.name } else { 'unknown' }
        $boardId   = if ($agent.PSObject.Properties["board_id"] -and $agent.board_id) { [string]$agent.board_id } elseif ($agent.id -eq '45167e3c-a016-40e0-a1d5-800a8f42ef42') { 'dd95369d-1497-41f2-8aeb-e06b51b63162' } else { '' }
        $isLead    = if ($agent.PSObject.Properties.Name -contains 'is_board_lead') { [bool]$agent.is_board_lead } else { $false }



        $token = Get-StableAgentToken -AgentId $agentId -LocalAuthToken $localAuthToken

        $workspacePath = Get-AgentWorkspacePath -AgentDetail $agent

        $bag.agents[$agentId] = [ordered]@{
            id              = $agentId
            name            = $agentName
            token           = $token
            workspace_path  = $workspacePath
            is_board_lead   = $isLead
            board_id        = $boardId
        }
    }

    $json = $bag | ConvertTo-Json -Depth 8
    $keyPath = [Environment]::GetFolderPath('UserProfile') + '/.mcon-secret.key'
    if (-not (Test-Path -LiteralPath $keyPath)) {
        throw "Key file not found at $keyPath. Generate with: pwsh -Command `"New-MconKey -KeyPath '$keyPath'`""
    }

    $encrypted = Protect-MconData -PlainText $json -KeyPath $keyPath
    $outputPath = Join-Path $PSScriptRoot '..\.agent-tokens.json.enc'
    $encrypted | Set-Content -LiteralPath $outputPath -Encoding UTF8

    Write-MconResult -Data ([ordered]@{
        ok          = $true
        action      = 'admin.gettokens'
        agent_count = $bag.agents.Count
        output      = $outputPath
        encrypted   = $true
    }) -Depth 12
}

function Invoke-MconAdminDecryptKeybag {
    [CmdletBinding()]
    param(
        [string]$InputPath = '~/.agent-tokens.json.enc',
        [string]$OutputPath = '~/.agent-tokens.json',
        [string]$KeyPath = '~/.mcon-secret.key',
        [string]$Wsp
    )

    $role = Resolve-MconRole -Wsp $Wsp
    if (-not (Test-MconPermission -Action 'admin.decrypt-keybag' -Role $role)) {
        $msg = Get-MconDeniedMessage -Action 'admin.decrypt-keybag' -Role $role
        Write-MconError -Message $msg -Code 'forbidden'
    }

    $resolvedInput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
    $resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $resolvedKey = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KeyPath)

    if (-not (Test-Path -LiteralPath $resolvedInput)) {
        throw "Encrypted keybag not found at $resolvedInput"
    }
    if (-not (Test-Path -LiteralPath $resolvedKey)) {
        throw "Key file not found at $resolvedKey"
    }

    $enc = Get-Content -LiteralPath $resolvedInput -Raw
    $json = Unprotect-MconData -EncryptedContent $enc -KeyPath $resolvedKey
    $json | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8

    Write-MconResult -Data ([ordered]@{
        ok        = $true
        action   = 'admin.decrypt-keybag'
        input    = $resolvedInput
        output   = $resolvedOutput
    }) -Depth 8
}

Export-ModuleMember -Function Invoke-MconAdminGetTokens, Invoke-MconAdminDecryptKeybag, Read-MconToolsMd, Get-StableAgentToken

