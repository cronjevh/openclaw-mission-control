param(
    [string]$OutputRoot = "C:\git\home-improvement\strategies\openclaw-mission-control\mission-control-links",
    [string]$Distro = "Ubuntu",
    [string]$ApiBaseUrl = "http://localhost:8002",
    [string]$UiBaseUrl = "http://localhost:3002",
    [switch]$DebugMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-WslUncPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LinuxPath
    )

    $normalized = $LinuxPath.Trim()
    if ($normalized.StartsWith("~/")) {
        $normalized = "/home/cronjev/" + $normalized.Substring(2)
    }
    elseif ($normalized -eq "~") {
        $normalized = "/home/cronjev"
    }

    $trimmed = $normalized.TrimStart([char[]]"/")
    $uncSuffix = $trimmed -replace "/", "\"
    return "\\wsl.localhost\$Distro\$uncSuffix"
}

function ConvertTo-SafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    $safe = $Value -replace '[<>:"/\\|?*]', "-"
    $safe = $safe -replace "\s+", " "
    $safe = $safe.Trim([char[]]" .")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return $Fallback
    }
    return $safe
}

function Get-UniqueName {
    param(
        [string]$Name,
        [System.Collections.Generic.HashSet[string]]$UsedNames,
        [string]$Suffix
    )

    if ($UsedNames.Add($Name)) {
        return $Name
    }

    $counter = 1
    while ($true) {
        $candidate = if ($counter -eq 1) {
            "$Name ($Suffix)"
        }
        else {
            "$Name ($Suffix-$counter)"
        }

        if ($UsedNames.Add($candidate)) {
            return $candidate
        }

        $counter += 1
    }
}

function Get-LocalAuthToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MissionControlEnvPath
    )

    if (-not (Test-Path -LiteralPath $MissionControlEnvPath)) {
        throw "Mission Control env file not found: $MissionControlEnvPath"
    }

    foreach ($line in Get-Content -LiteralPath $MissionControlEnvPath) {
        if ($line -like "LOCAL_AUTH_TOKEN=*") {
            $token = $line.Substring("LOCAL_AUTH_TOKEN=".Length).Trim()
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                return $token
            }
        }
    }

    throw "LOCAL_AUTH_TOKEN not found in $MissionControlEnvPath"
}

function Invoke-MissionControlApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $headers = @{
        Authorization = "Bearer $Token"
    }

    return Invoke-RestMethod -Uri ($ApiBaseUrl + $Path) -Headers $headers -Method Get
}

function Get-PagedMissionControlItems {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $items = New-Object System.Collections.Generic.List[object]
    $limit = 200
    $offset = 0

    while ($true) {
        $separator = if ($Path.Contains("?")) { "&" } else { "?" }
        $response = Invoke-MissionControlApi -Path "$Path${separator}limit=$limit&offset=$offset" -Token $Token

        if ($null -ne $response.items) {
            $batch = @($response.items)
        }
        elseif ($response -is [System.Array]) {
            $batch = @($response)
        }
        else {
            throw "Unexpected API payload for $Path"
        }

        foreach ($item in $batch) {
            [void]$items.Add($item)
        }

        if ($batch.Count -lt $limit) {
            break
        }

        $offset += $limit
    }

    return $items.ToArray()
}

function Get-OpenClawAgents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenClawJsonPath
    )

    if (-not (Test-Path -LiteralPath $OpenClawJsonPath)) {
        throw "openclaw.json not found: $OpenClawJsonPath"
    }

    $config = Get-Content -LiteralPath $OpenClawJsonPath -Raw | ConvertFrom-Json
    $agents = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    $bySession = @{}

    foreach ($item in @($config.agents.list)) {
        $agentIdProperty = $item.PSObject.Properties["id"]
        $workspaceProperty = $item.PSObject.Properties["workspace"]
        $nameProperty = $item.PSObject.Properties["name"]

        $agentId = if ($null -ne $agentIdProperty) { [string]$agentIdProperty.Value } else { "" }
        $workspace = if ($null -ne $workspaceProperty) { [string]$workspaceProperty.Value } else { "" }
        $displayName = if ($null -ne $nameProperty) { [string]$nameProperty.Value } else { "" }

        if ([string]::IsNullOrWhiteSpace($agentId) -or [string]::IsNullOrWhiteSpace($workspace)) {
            continue
        }

        $agent = [pscustomobject]@{
            AgentId      = $agentId
            Name         = if ([string]::IsNullOrWhiteSpace($displayName)) { $agentId } else { $displayName }
            Workspace    = $workspace
            WorkspaceUnc = Get-WslUncPath -LinuxPath $workspace
            SessionId    = "agent:${agentId}:main"
        }

        [void]$agents.Add($agent)
        $byId[$agent.AgentId] = $agent
        $bySession[$agent.SessionId] = $agent
    }

    return [pscustomobject]@{
        Agents    = $agents.ToArray()
        ById      = $byId
        BySession = $bySession
    }
}

function Resolve-OpenClawAgent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$MissionControlAgent,
        [Parameter(Mandatory = $true)]
        [hashtable]$ById,
        [Parameter(Mandatory = $true)]
        [hashtable]$BySession
    )

    if ($MissionControlAgent.openclaw_session_id -and $BySession.ContainsKey([string]$MissionControlAgent.openclaw_session_id)) {
        return $BySession[[string]$MissionControlAgent.openclaw_session_id]
    }

    if ($MissionControlAgent.is_board_lead -and $MissionControlAgent.board_id) {
        $leadId = "lead-$($MissionControlAgent.board_id)"
        if ($ById.ContainsKey($leadId)) {
            return $ById[$leadId]
        }
    }

    $candidates = @(
        [string]$MissionControlAgent.id,
        "mc-$($MissionControlAgent.id)",
        [string]$MissionControlAgent.name
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $ById.ContainsKey($candidate)) {
            return $ById[$candidate]
        }
    }

    return $null
}

function Clean-DefunctSymlinks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,
        [Parameter(Mandatory = $true)]
        [object[]]$CurrentAgents,
        [Parameter(Mandatory = $true)]
        [object[]]$CurrentBoardMembers
    )

    # Handle empty arrays gracefully
    if ($CurrentAgents -eq $null -or $CurrentAgents.Count -eq 0) {
        $CurrentAgents = @()
    }
    
    if ($CurrentBoardMembers -eq $null -or $CurrentBoardMembers.Count -eq 0) {
        $CurrentBoardMembers = @()
    }

    # Create a set of all current symlink targets that should exist
    $currentSymlinkTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    
    # Add all agent workspace paths
    foreach ($agent in $CurrentAgents) {
        [void]$currentSymlinkTargets.Add($agent.WorkspaceUnc)
    }
    
    # Add all board member workspace paths
    foreach ($member in $CurrentBoardMembers) {
        if ($member.Resolved -and $member.Resolved.WorkspaceUnc) {
            [void]$currentSymlinkTargets.Add($member.Resolved.WorkspaceUnc)
        }
    }

    # Clean up defunct agent symlinks
    $agentsDir = Join-Path $OutputRoot "agents"
    if (Test-Path -LiteralPath $agentsDir) {
        $existingAgentLinks = Get-ChildItem -LiteralPath $agentsDir -Directory
        foreach ($link in $existingAgentLinks) {
            # Check if it's a symlink (either by LinkType or by checking if target exists and is different)
            $isSymlink = $false
            $targetPath = $null
            
            if ($link.LinkType -eq "SymbolicLink") {
                $isSymlink = $true
                $targetPath = $link.Target
            } elseif ($link.PSObject.Properties["Target"]) {
                # Some symlink types might have Target property
                $targetPath = $link.Target
                $isSymlink = $true
            } else {
                # Fallback: check if it's a reparse point (common for symlinks on Windows)
                $isSymlink = $link.Attributes -band [System.IO.FileAttributes]::ReparsePoint
            }
            
            if ($isSymlink -and $targetPath -and -not $currentSymlinkTargets.Contains($targetPath)) {
                Write-Host "[removing-defunct-agent-link] $($link.FullName) -> $targetPath"
                Remove-Item -LiteralPath $link.FullName -Recurse -Force
            }
        }
    }

    # Clean up defunct board member symlinks
    $boardsDir = Join-Path $OutputRoot "boards"
    if (Test-Path -LiteralPath $boardsDir) {
        $boardDirs = Get-ChildItem -LiteralPath $boardsDir -Directory
        foreach ($boardDir in $boardDirs) {
            $memberLinks = Get-ChildItem -LiteralPath $boardDir.FullName -Directory
            foreach ($link in $memberLinks) {
                # Check if it's a symlink (either by LinkType or by checking if target exists and is different)
                $isSymlink = $false
                $targetPath = $null
                
                if ($link.LinkType -eq "SymbolicLink") {
                    $isSymlink = $true
                    $targetPath = $link.Target
                } elseif ($link.PSObject.Properties["Target"]) {
                    # Some symlink types might have Target property
                    $targetPath = $link.Target
                    $isSymlink = $true
                } else {
                    # Fallback: check if it's a reparse point (common for symlinks on Windows)
                    $isSymlink = $link.Attributes -band [System.IO.FileAttributes]::ReparsePoint
                }
                
                if ($isSymlink -and $targetPath -and -not $currentSymlinkTargets.Contains($targetPath)) {
                    Write-Host "[removing-defunct-board-link] $($link.FullName) -> $targetPath"
                    Remove-Item -LiteralPath $link.FullName -Recurse -Force
                }
            }
        }
    }
}

function Initialize-OutputRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }

    # Ensure required directories exist
    $requiredDirs = @(
        (Join-Path $Path "boards"),
        (Join-Path $Path "agents")
    )

    foreach ($dir in $requiredDirs) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir | Out-Null
        }
    }
}

function Write-MarkdownFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, [string]$Content, $utf8NoBom)
}

function Test-WorkspacePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    Write-Host "[debug] Testing workspace path: $WorkspacePath" -ForegroundColor Cyan
    
    # Check if it's a WSL UNC path (the actual format used in the script)
    if ($WorkspacePath.StartsWith("\\wsl.localhost\")) {
        Write-Host "[debug] Path appears to be WSL UNC format" -ForegroundColor Cyan
        # For WSL paths, we consider them valid if they have the correct format
        # Actual accessibility testing would require WSL access, which we don't have from this script
        if ($WorkspacePath -match "^\\\\wsl\.localhost\\[^\\]+\\.*") {
            Write-Host "[info] WSL UNC path format appears valid: $WorkspacePath" -ForegroundColor Green
            return $true
        } else {
            Write-Host "[warning] WSL UNC path format invalid: $WorkspacePath" -ForegroundColor Yellow
            return $false
        }
    }
    
    # Regular Windows path
    if (Test-Path -LiteralPath $WorkspacePath) {
        Write-Host "[success] Windows path exists: $WorkspacePath" -ForegroundColor Green
        return $true
    } else {
        Write-Host "[error] Windows path does not exist: $WorkspacePath" -ForegroundColor Red
        return $false
    }
}

function Write-PlannedLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LinkPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    Write-Host "[planned-link] $LinkPath -> $TargetPath"

    # Debug validation - check if target exists
    if ($DebugMode) {
        Test-WorkspacePath -WorkspacePath $TargetPath
    } elseif (-not (Test-Path -LiteralPath $TargetPath)) {
        Write-Host "[warning] Target path does not exist: $TargetPath" -ForegroundColor Yellow
    } else {
        Write-Host "[info] Target path exists: $TargetPath" -ForegroundColor Green
    }

    # In debug mode, skip actual symlink creation (requires elevation)
    if ($DebugMode) {
        Write-Host "[debug] Skipping symlink creation (DebugMode enabled)" -ForegroundColor Cyan
        return
    }

    # Requires elevation / admin mode on Windows when targeting WSL UNC paths.
    if (Test-Path -LiteralPath $LinkPath) {
        $existingItem = Get-Item -LiteralPath $LinkPath -Force
        if ($existingItem.PSIsContainer) {
            Remove-Item -LiteralPath $LinkPath -Recurse -Force
        }
        else {
            Remove-Item -LiteralPath $LinkPath -Force
        }
    }
    
    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath | Out-Null
        Write-Host "[success] Symlink created: $LinkPath -> $TargetPath" -ForegroundColor Green
    } catch {
        Write-Host "[error] Failed to create symlink: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Get-BoardReadmeContent {
    param(
        [object]$Board,
        [object[]]$LinkedAgents,
        [object[]]$MissingAgents
    )

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# $($Board.name)")
    [void]$lines.Add("")
    [void]$lines.Add("- Board ID: '$($Board.id)'")
    [void]$lines.Add("- Mission Control URL: $UiBaseUrl/boards/$($Board.id)")

    if (-not [string]::IsNullOrWhiteSpace([string]$Board.description)) {
        [void]$lines.Add("")
        [void]$lines.Add("## Description")
        [void]$lines.Add("")
        [void]$lines.Add([string]$Board.description)
    }

    [void]$lines.Add("")
    [void]$lines.Add("## Linked Workspaces")
    [void]$lines.Add("")

    foreach ($agent in $LinkedAgents) {
        [void]$lines.Add("- **$($agent.Name)**  ")
        [void]$lines.Add("  MC Agent ID: ``$($agent.MissionControlId)``  ")
        [void]$lines.Add("  OpenClaw ID: ``$($agent.OpenClawId)``  ")
        [void]$lines.Add("  Workspace: ``$($agent.WorkspaceLinuxPath)``")
        [void]$lines.Add("")
    }

    if ($MissingAgents.Count -gt 0) {
        [void]$lines.Add("## Missing Workspace Mappings")
        [void]$lines.Add("")
        foreach ($agent in $MissingAgents) {
            [void]$lines.Add("- **$($agent.Name)** (`$($agent.MissionControlId)`)") 
        }
        [void]$lines.Add("")
    }

    return ($lines -join "`r`n")
}

function Get-AgentsReadmeContent {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Agents
    )

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# Agents")
    [void]$lines.Add("")
    [void]$lines.Add("Mission Control URL: $UiBaseUrl/agents")
    [void]$lines.Add("")

    foreach ($agent in $Agents) {
        [void]$lines.Add("- **$($agent.Name)**  ")
        [void]$lines.Add("  OpenClaw ID: ``$($agent.AgentId)``  ")
        [void]$lines.Add("  Workspace: ``$($agent.Workspace)``")
        [void]$lines.Add("")
    }

    return ($lines -join "`r`n")
}

function Get-RootReadmeContent {
    param(
        [Parameter(Mandatory = $true)]
        [int]$BoardCount,
        [Parameter(Mandatory = $true)]
        [int]$AgentCount,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    return @"
# Mission Control Links

This folder is generated by mission-control-links/scripts/New-MissionControlWorkspaceLinks.ps1.

- Boards UI: $UiBaseUrl/boards
- Agents UI: $UiBaseUrl/agents
- Output root: $OutputPath
- Boards discovered: $BoardCount
- OpenClaw agents discovered: $AgentCount

For now, the script only prints the symbolic links it would create.
The script refreshes the symbolic links and README files from the live Mission Control state.
"@
}

$openClawJsonPath = Get-WslUncPath -LinuxPath "/home/cronjev/.openclaw/openclaw.json"
$missionControlEnvPath = Get-WslUncPath -LinuxPath "/home/cronjev/mission-control-tfsmrt/backend/.env"

$token = Get-LocalAuthToken -MissionControlEnvPath $missionControlEnvPath
$openClaw = Get-OpenClawAgents -OpenClawJsonPath $openClawJsonPath
$boards = @(Get-PagedMissionControlItems -Path "/api/v1/boards" -Token $token | Sort-Object -Property name)
$missionControlAgents = @(Get-PagedMissionControlItems -Path "/api/v1/agents" -Token $token)

Initialize-OutputRoot -Path $OutputRoot

$agentLinksDir = Join-Path $OutputRoot "agents"
$boardLinksDir = Join-Path $OutputRoot "boards"

$usedAgentNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$boardMembersForCleanup = New-Object System.Collections.Generic.List[object]

foreach ($agent in ($openClaw.Agents | Sort-Object -Property Name, AgentId)) {
    $safeName = ConvertTo-SafeName -Value $agent.Name -Fallback $agent.AgentId
    $linkName = Get-UniqueName -Name $safeName -UsedNames $usedAgentNames -Suffix ($agent.AgentId.Substring(0, [Math]::Min(8, $agent.AgentId.Length)))
    $linkPath = Join-Path $agentLinksDir $linkName
    Write-PlannedLink -LinkPath $linkPath -TargetPath $agent.WorkspaceUnc
}

Write-MarkdownFile -Path (Join-Path $agentLinksDir "README.md") -Content (Get-AgentsReadmeContent -Agents ($openClaw.Agents | Sort-Object -Property Name, AgentId))

$usedBoardNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$linkedBoardCount = 0

foreach ($board in $boards) {
    # Skip boards with invalid or empty names/IDs
    if ([string]::IsNullOrWhiteSpace($board.id) -or [string]::IsNullOrWhiteSpace($board.name)) {
        Write-Host "[warning] Skipping board with invalid ID or name: ID='$($board.id)', Name='$($board.name)'" -ForegroundColor Yellow
        continue
    }
    
    $members = @($missionControlAgents | Where-Object { $_.board_id -eq $board.id })
    if ($members.Count -eq 0) {
        continue
    }

    $boardSafeName = ConvertTo-SafeName -Value ([string]$board.name) -Fallback ([string]$board.id)
    $boardFolderName = Get-UniqueName -Name $boardSafeName -UsedNames $usedBoardNames -Suffix ([string]$board.id).Substring(0, 8)
    $boardFolderPath = Join-Path $boardLinksDir $boardFolderName
    New-Item -ItemType Directory -Path $boardFolderPath -Force | Out-Null

    $linkedAgents = New-Object System.Collections.Generic.List[object]
    $missingAgents = New-Object System.Collections.Generic.List[object]
    $usedMemberNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($member in ($members | Sort-Object -Property @{ Expression = { -not $_.is_board_lead } }, name, id)) {
        $resolved = Resolve-OpenClawAgent -MissionControlAgent $member -ById $openClaw.ById -BySession $openClaw.BySession

        if ($null -eq $resolved) {
            [void]$missingAgents.Add([pscustomobject]@{
                Name             = [string]$member.name
                MissionControlId = [string]$member.id
            })
            continue
        }

        # Add resolved agent to cleanup list
        [void]$boardMembersForCleanup.Add([pscustomobject]@{
            Member = $member
            Resolved = $resolved
        })

        $safeMemberName = ConvertTo-SafeName -Value $resolved.Name -Fallback $resolved.AgentId
        $memberLinkName = Get-UniqueName -Name $safeMemberName -UsedNames $usedMemberNames -Suffix ([string]$member.id).Substring(0, 8)
        $memberLinkPath = Join-Path $boardFolderPath $memberLinkName
        Write-PlannedLink -LinkPath $memberLinkPath -TargetPath $resolved.WorkspaceUnc

        [void]$linkedAgents.Add([pscustomobject]@{
            Name               = $resolved.Name
            MissionControlId   = [string]$member.id
            OpenClawId         = $resolved.AgentId
            WorkspaceLinuxPath = $resolved.Workspace
        })
    }

    $linkedAgentsArray = $linkedAgents.ToArray()
    $missingAgentsArray = $missingAgents.ToArray()
    Write-MarkdownFile -Path (Join-Path $boardFolderPath "README.md") -Content (Get-BoardReadmeContent -Board $board -LinkedAgents $linkedAgentsArray -MissingAgents $missingAgentsArray)
    $linkedBoardCount += 1
}

Write-MarkdownFile -Path (Join-Path $OutputRoot "README.md") -Content (Get-RootReadmeContent -BoardCount $linkedBoardCount -AgentCount $openClaw.Agents.Count -OutputPath $OutputRoot)

# Clean up any defunct symlinks after processing all boards and agents
Clean-DefunctSymlinks -OutputRoot $OutputRoot -CurrentAgents $openClaw.Agents -CurrentBoardMembers $boardMembersForCleanup

Write-Host ""
Write-Host "Prepared output folder: $OutputRoot"
Write-Host "Boards with members: $linkedBoardCount"
Write-Host "OpenClaw agents: $($openClaw.Agents.Count)"
