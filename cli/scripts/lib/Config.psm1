$script:ValidStatuses = @('inbox', 'in_progress', 'review', 'done', 'blocked')

function Resolve-MconConfig {
    [CmdletBinding()]
    param(
        [string]$BaseUrl,
        [string]$AuthToken,
        [string]$BoardId
    )

    $resolvedBase = if ($BaseUrl) { $BaseUrl } elseif ($env:MCON_BASE_URL) { $env:MCON_BASE_URL } else { $null }
    $resolvedToken = if ($AuthToken) { $AuthToken } elseif ($env:MCON_AUTH_TOKEN) { $env:MCON_AUTH_TOKEN } else { $null }
    $resolvedBoard = if ($BoardId) { $BoardId } elseif ($env:MCON_BOARD_ID) { $env:MCON_BOARD_ID } else { $null }
    $resolvedWsp = if ($env:MCON_WSP) { $env:MCON_WSP } else { $null }

    if (-not $resolvedBase -or -not $resolvedToken -or -not $resolvedBoard) {
        $envFile = Find-MconEnvFile
        if ($envFile) {
            $envMap = Parse-MconEnvFile -Path $envFile
            if (-not $resolvedBase -and $envMap.ContainsKey('MCON_BASE_URL')) { $resolvedBase = $envMap['MCON_BASE_URL'] }
            if (-not $resolvedToken -and $envMap.ContainsKey('MCON_AUTH_TOKEN')) { $resolvedToken = $envMap['MCON_AUTH_TOKEN'] }
            if (-not $resolvedBoard -and $envMap.ContainsKey('MCON_BOARD_ID')) { $resolvedBoard = $envMap['MCON_BOARD_ID'] }
            if (-not $resolvedWsp -and $envMap.ContainsKey('MCON_WSP')) { $resolvedWsp = $envMap['MCON_WSP'] }
        }
    }

    if (-not $resolvedBase -or -not $resolvedToken -or -not $resolvedBoard) {
        $toolsMap = Find-MconToolsConfig
        if ($toolsMap) {
            if (-not $resolvedBase -and $toolsMap.ContainsKey('BASE_URL')) { $resolvedBase = $toolsMap['BASE_URL'] }
            if (-not $resolvedToken -and $toolsMap.ContainsKey('AUTH_TOKEN')) { $resolvedToken = $toolsMap['AUTH_TOKEN'] }
            if (-not $resolvedBoard -and $toolsMap.ContainsKey('BOARD_ID')) { $resolvedBoard = $toolsMap['BOARD_ID'] }
        }
    }

    $errors = @()
    if (-not $resolvedBase) { $errors += 'MCON_BASE_URL' }
    if (-not $resolvedToken) { $errors += 'MCON_AUTH_TOKEN' }
    if (-not $resolvedBoard) { $errors += 'MCON_BOARD_ID' }

    if ($errors.Count -gt 0) {
        throw "Missing required config: $($errors -join ', '). Set env vars, .mcon.env, or TOOLS.md."
    }

    if (-not $resolvedWsp) {
        throw "Missing required config: MCON_WSP. Set the workspace name (e.g. workspace-lead-*, workspace-gateway-*, workspace-mc-*)."
    }

    return [ordered]@{
        base_url   = $resolvedBase.TrimEnd('/')
        auth_token = $resolvedToken
        board_id   = $resolvedBoard
        wsp        = $resolvedWsp
    }
}

function Find-MconEnvFile {
    $candidates = @(
        (Join-Path $PWD '.mcon.env'),
        (Join-Path $PSScriptRoot '../../.mcon.env'),
        (Join-Path $env:HOME '.mcon.env')
    )
    foreach ($p in $candidates) {
        $resolved = if (Test-Path -LiteralPath $p) { (Resolve-Path -LiteralPath $p).Path } else { $null }
        if ($resolved) { return $resolved }
    }
    return $null
}

function Parse-MconEnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.+?)\s*$') {
            $map[$matches[1]] = $matches[2].Trim('"', "'")
        }
    }
    return $map
}

function Find-MconToolsConfig {
    $workspaceRoots = @(
        '/home/cronjev/.openclaw'
    )
    foreach ($root in $workspaceRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^workspace-' }
        foreach ($dir in $dirs) {
            $toolsPath = Join-Path $dir.FullName 'TOOLS.md'
            if (Test-Path -LiteralPath $toolsPath) {
                return Read-MconToolsMd -Path $toolsPath
            }
        }
    }
    return $null
}

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

function Test-MconValidStatus {
    param([Parameter(Mandatory)][string]$Status)
    return $script:ValidStatuses -contains $Status.ToLowerInvariant()
}

function Get-MconValidStatuses {
    return $script:ValidStatuses
}

function Resolve-MconWsp {
    $resolvedWsp = if ($env:MCON_WSP) { $env:MCON_WSP } else { $null }

    if (-not $resolvedWsp) {
        $envFile = Find-MconEnvFile
        if ($envFile) {
            $envMap = Parse-MconEnvFile -Path $envFile
            if ($envMap.ContainsKey('MCON_WSP')) { $resolvedWsp = $envMap['MCON_WSP'] }
        }
    }

    if (-not $resolvedWsp) {
        $toolsMap = Find-MconToolsConfig
        if ($toolsMap) {
            # Not applicable for WSP
        }
    }

    return $resolvedWsp
}

function Resolve-MconKeybagAgent {
    [CmdletBinding()]
    param()

    if ($env:MCON_AUTH_TOKEN) {
        $wsp = $env:MCON_WSP
        $workspacePath = Join-Path '/home/cronjev/.openclaw' $wsp
        return [ordered]@{
            base_url       = $env:MCON_BASE_URL
            auth_token     = $env:MCON_AUTH_TOKEN
            board_id       = $env:MCON_BOARD_ID
            agent_id       = $env:MCON_AGENT_ID
            wsp            = $wsp
            workspace_path = $workspacePath
        }
    }

    $keybagPath = Join-Path (Split-Path $PSScriptRoot -Parent) '.agent-tokens.json.enc'
    if (-not (Test-Path -LiteralPath $keybagPath)) {
        return $null
    }

    $encContent = Get-Content -LiteralPath $keybagPath -Raw
    $resolvedKey = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('~/.mcon-secret.key')
    if (-not (Test-Path -LiteralPath $resolvedKey)) {
        throw "Key file not found at $resolvedKey."
    }
    $key = Get-Content -Path $resolvedKey -AsByteStream
    $secureString = ConvertTo-SecureString -String $encContent -Key $key
    $bstrPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    $jsonContent = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrPtr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrPtr)
    $keybag = $jsonContent | ConvertFrom-Json

    $path = (Get-Location).Path
    $matchingAgent = $null
    foreach ($aid in $keybag.agents.PSObject.Properties.Name) {
        $agent = $keybag.agents.$aid
        if ($agent.workspace_path -eq $path) {
            $matchingAgent = $agent
            break
        }
    }

    if (-not $matchingAgent) {
        return $null
    }

    $wsp = Split-Path $matchingAgent.workspace_path -Leaf

    $env:MCON_BASE_URL = if ($keybag.base_url) { $keybag.base_url } else { 'http://localhost:8002' }
    $env:MCON_AUTH_TOKEN = $matchingAgent.token
    $env:MCON_BOARD_ID = $matchingAgent.board_id
    $env:MCON_AGENT_ID = $matchingAgent.id
    $env:MCON_WSP = $wsp

    return [ordered]@{
        base_url       = $env:MCON_BASE_URL
        auth_token     = $matchingAgent.token
        board_id       = $matchingAgent.board_id
        agent_id       = $matchingAgent.id
        wsp            = $wsp
        workspace_path = $matchingAgent.workspace_path
    }
}

function Get-MconWorkspacePathFromWsp {
    param([Parameter(Mandatory)][string]$Wsp)

    return Join-Path '/home/cronjev/.openclaw' $Wsp
}

function Get-MconDecryptedKeybag {
    [CmdletBinding()]
    param()

    $keybagPath = Join-Path (Split-Path $PSScriptRoot -Parent) '.agent-tokens.json.enc'
    if (-not (Test-Path -LiteralPath $keybagPath)) {
        return $null
    }

    $encContent = Get-Content -LiteralPath $keybagPath -Raw
    $resolvedKey = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('~/.mcon-secret.key')
    if (-not (Test-Path -LiteralPath $resolvedKey)) {
        throw "Key file not found at $resolvedKey."
    }
    $key = Get-Content -Path $resolvedKey -AsByteStream
    $secureString = ConvertTo-SecureString -String $encContent -Key $key
    $bstrPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        $jsonContent = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrPtr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrPtr)
    }

    return $jsonContent | ConvertFrom-Json
}

function Resolve-MconLeadAgentConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BoardId
    )

    $keybag = Get-MconDecryptedKeybag
    if (-not $keybag) {
        return $null
    }

    foreach ($aid in $keybag.agents.PSObject.Properties.Name) {
        $agent = $keybag.agents.$aid
        if ($agent.is_board_lead -and $agent.board_id -eq $BoardId) {
            return [ordered]@{
                base_url       = if ($keybag.base_url) { $keybag.base_url } else { 'http://localhost:8002' }
                auth_token     = $agent.token
                board_id       = $agent.board_id
                agent_id       = $agent.id
                wsp            = (Split-Path $agent.workspace_path -Leaf)
                workspace_path = $agent.workspace_path
            }
        }
    }

    return $null
}

function Get-MconOpenClawConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $resolvedWorkspacePath = (Resolve-Path -LiteralPath $WorkspacePath).Path
    $openClawRoot = Split-Path -Parent $resolvedWorkspacePath
    $configPath = Join-Path $openClawRoot 'openclaw.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "OpenClaw config not found at $configPath."
    }

    return (Resolve-Path -LiteralPath $configPath).Path
}

function Get-MconOpenClawConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $configPath = Get-MconOpenClawConfigPath -WorkspacePath $WorkspacePath
    try {
        return (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100)
    } catch {
        throw "Failed to read OpenClaw config $configPath : $($_.Exception.Message)"
    }
}

function Resolve-MconNormalizedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $providerPath) {
        return (Resolve-Path -LiteralPath $providerPath).Path
    }

    return $providerPath
}

function Resolve-MconOpenClawAgentConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $resolvedWorkspacePath = Resolve-MconNormalizedPath -Path $WorkspacePath
    $config = Get-MconOpenClawConfig -WorkspacePath $resolvedWorkspacePath
    if (-not $config -or -not ($config.PSObject.Properties.Name -contains 'agents') -or -not $config.agents) {
        throw "OpenClaw config is missing an agents registry for workspace $WorkspacePath."
    }

    $agentEntries = @()
    if ($config.agents.PSObject.Properties.Name -contains 'list' -and $config.agents.list) {
        $agentEntries = @($config.agents.list | Where-Object { $_ })
    }

    foreach ($agent in $agentEntries) {
        $agentWorkspace = $null
        if ($agent.PSObject.Properties.Name -contains 'workspace' -and $agent.workspace) {
            $agentWorkspace = [string]$agent.workspace
        } elseif ($agent.PSObject.Properties.Name -contains 'workspace_path' -and $agent.workspace_path) {
            $agentWorkspace = [string]$agent.workspace_path
        }

        if ([string]::IsNullOrWhiteSpace($agentWorkspace)) {
            continue
        }

        $resolvedAgentWorkspace = Resolve-MconNormalizedPath -Path $agentWorkspace
        if ($resolvedAgentWorkspace -ne $resolvedWorkspacePath) {
            continue
        }

        $agentName = $null
        if ($agent.PSObject.Properties.Name -contains 'name' -and $agent.name) {
            $agentName = [string]$agent.name
        } elseif ($agent.PSObject.Properties.Name -contains 'identity' -and $agent.identity -and $agent.identity.PSObject.Properties.Name -contains 'name') {
            $agentName = [string]$agent.identity.name
        }

        if ([string]::IsNullOrWhiteSpace($agentName)) {
            throw "OpenClaw agent entry for workspace $WorkspacePath is missing a canonical name."
        }

        $displayName = $agentName.Trim()
        $configId = if ($agent.PSObject.Properties.Name -contains 'id' -and $agent.id) { [string]$agent.id } else { $null }
        if ([string]::IsNullOrWhiteSpace($configId)) {
            throw "OpenClaw agent entry for workspace $WorkspacePath is missing a canonical id."
        }
        return [ordered]@{
            config_id      = $configId
            name           = $displayName
            agent_id       = $displayName.ToLowerInvariant()
            spawn_agent_id = $configId
            workspace      = $resolvedWorkspacePath
        }
    }

    throw "No OpenClaw agent entry found for workspace path: $WorkspacePath"
}

function Resolve-MconOpenClawAgentName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    return (Resolve-MconOpenClawAgentConfig -WorkspacePath $WorkspacePath).name
}

Export-ModuleMember -Function Resolve-MconConfig, Resolve-MconWsp, Test-MconValidStatus, Get-MconValidStatuses, Resolve-MconKeybagAgent, Get-MconWorkspacePathFromWsp, Get-MconDecryptedKeybag, Resolve-MconLeadAgentConfig, Get-MconOpenClawConfigPath, Get-MconOpenClawConfig, Resolve-MconOpenClawAgentConfig, Resolve-MconOpenClawAgentName
