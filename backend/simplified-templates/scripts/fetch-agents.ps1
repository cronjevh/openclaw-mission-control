param(
    [string]$EnvPath = "backend/.env",
    [string]$BaseUrl = "http://localhost:8002",
    [string]$AgentsPath = "/api/v1/agents",
    [string]$OutputPath = "backend/simplified-templates/template-update.json",
    [string]$RenderRoot = "/home/cronjev/.openclaw"
)

function Get-DotEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Dotenv file not found: $Path"
    }

    $line = Get-Content -LiteralPath $Path | Where-Object {
        $_ -match "^\s*$([regex]::Escape($Name))="
    } | Select-Object -First 1

    if (-not $line) {
        throw "Missing required key '$Name' in $Path"
    }

    return ($line -split '=', 2)[1].Trim()
}

function Get-StableAgentToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AgentId,
        [Parameter(Mandatory = $true)]
        [string]$LocalAuthToken
    )

    $message = [Text.Encoding]::UTF8.GetBytes("mission-control-agent-token:v1:$AgentId")
    $key = [Text.Encoding]::UTF8.GetBytes($LocalAuthToken.Trim())
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    try {
        $digest = $hmac.ComputeHash($message)
    } finally {
        $hmac.Dispose()
    }
    $base64 = [Convert]::ToBase64String($digest).TrimEnd("=")
    $base64 = $base64.Replace("+", "-").Replace("/", "_")
    return "mca_$base64"
}

function ConvertFrom-AgentListResponse {
    param(
        [Parameter(Mandatory = $true)]
        $Response
    )

    if ($Response -is [System.Collections.IEnumerable] -and $Response -isnot [string]) {
        return @($Response)
    }

    foreach ($propertyName in @("agents", "items", "data", "results")) {
        $value = $Response.$propertyName
        if ($null -ne $value) {
            return @($value)
        }
    }

    throw "Unrecognized agent list response shape."
}

function Get-AgentId {
    param(
        [Parameter(Mandatory = $true)]
        $Agent
    )

    foreach ($propertyName in @("id", "agent_id", "agentId")) {
        $value = $Agent.$propertyName
        if ($value) {
            return [string]$value
        }
    }

    throw "Agent record does not include an id field."
}

function Get-TemplateValueMap {
    param(
        [Parameter(Mandatory = $true)]
        $Detail,
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$AuthToken,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    $map = [ordered]@{}

    $map.base_url = $BaseUrl
    $map.auth_token = $AuthToken
    $map.workspace_root = $WorkspaceRoot
    $map.workspace_path = $WorkspacePath
    $map.board_id = [string]$Detail.board_id
    $map.name = [string]$Detail.name
    $map.id = [string]$Detail.id
    $resolvedRole = $null
    if ($Detail.identity_profile -and $Detail.identity_profile.PSObject.Properties["role"]) {
        $resolvedRole = [string]$Detail.identity_profile.role
    } elseif ($Detail.PSObject.Properties["role"]) {
        $resolvedRole = [string]$Detail.role
    }
    $map["identity_profile.role"] = $resolvedRole

    if ($Detail.identity_profile) {
        foreach ($property in $Detail.identity_profile.PSObject.Properties) {
            if ($null -ne $property.Value -and -not $map.Contains($property.Name) -and -not $map.Contains("identity_profile.$($property.Name)")) {
                $map["identity_profile.$($property.Name)"] = [string]$property.Value
            }
        }
    }

    if ($Detail.heartbeat_config) {
        foreach ($property in $Detail.heartbeat_config.PSObject.Properties) {
            if ($null -ne $property.Value -and -not $map.Contains($property.Name)) {
                $map["heartbeat_config.$($property.Name)"] = [string]$property.Value
            }
        }
    }

    foreach ($propertyName in @(
        "gateway_id",
        "group_id",
        "is_board_lead",
        "is_gateway_main",
        "openclaw_session_id",
        "identity_template",
        "soul_template",
        "last_seen_at",
        "created_at",
        "updated_at"
    )) {
        $value = $Detail.$propertyName
        if ($null -ne $value) {
            $map[$propertyName] = [string]$value
        }
    }

    return [pscustomobject]@{
        Values        = $map
        WorkspacePath = $WorkspacePath
    }
}

function Get-AgentTemplatePrefix {
    param(
        [Parameter(Mandatory = $true)]
        $Detail
    )

    $isLead = $false
    if ($Detail.PSObject.Properties["is_board_lead"]) {
        $isLead = [bool]$Detail.is_board_lead
    }
    if (-not $isLead -and $Detail.PSObject.Properties["is_gateway_main"]) {
        $isLead = [bool]$Detail.is_gateway_main
    }

    if ($isLead) {
        return "BOARD_LEAD_"
    }

    return "BOARD_WORKER_"
}

function Get-AgentWorkspacePath {
    param(
        [Parameter(Mandatory = $true)]
        $Detail,
        [Parameter(Mandatory = $true)]
        [string]$RenderRoot
    )

    $isLead = $false
    if ($Detail.PSObject.Properties["is_board_lead"]) {
        $isLead = [bool]$Detail.is_board_lead
    }
    if (-not $isLead -and $Detail.PSObject.Properties["is_gateway_main"]) {
        $isLead = [bool]$Detail.is_gateway_main
    }

    if ($isLead) {
        if (-not $Detail.board_id) {
            return $null
        }

        return Join-Path $RenderRoot "workspace-lead-$([string]$Detail.board_id)"
    }

    if (-not $Detail.id) {
        throw "Worker agent '$($Detail.name)' is missing id."
    }

    return Join-Path $RenderRoot "workspace-mc-$([string]$Detail.id)"
}

function Render-WorkspaceTemplates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePrefix,
        [Parameter(Mandatory = $true)]
        [string]$TargetWorkspacePath,
        [Parameter(Mandatory = $true)]
        $Values
    )

    $templateFiles = Get-ChildItem -Path 'backend/simplified-templates' -Filter "$TemplatePrefix*.md" -File | Sort-Object Name
    $templateLimitBytes = 40KB
    $renderedTemplates = @()
    $renderedBytes = 0

    foreach ($templateFile in $templateFiles) {
        $targetFileName = $templateFile.Name -replace ('^' + [regex]::Escape($TemplatePrefix)), ''
        $targetPath = Join-Path $TargetWorkspacePath $targetFileName
        $targetDirectory = Split-Path -Parent $targetPath
        if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        }
        $existingContent = if (Test-Path -LiteralPath $targetPath) {
            Get-Content -LiteralPath $targetPath -Raw
        } else {
            $null
        }
        $templateContent = Get-Content -LiteralPath $templateFile.FullName -Raw
        $renderedContent = Render-TemplateContent -Content $templateContent -Values $Values

        if ($null -ne $existingContent -and -not $existingContent.EndsWith("`n")) {
            $renderedContent = $renderedContent -replace '\r?\n\z', ''
        } elseif ($null -ne $existingContent -and -not $renderedContent.EndsWith("`n")) {
            $renderedContent += "`n"
        }

        $renderedBytes += [System.Text.Encoding]::UTF8.GetByteCount($renderedContent)
        $renderedTemplates += [pscustomobject]@{
            Path    = $targetPath
            Content = $renderedContent
        }
    }

    if ($renderedBytes -ge $templateLimitBytes) {
        throw "Rendered template bundle for '$TemplatePrefix' is $renderedBytes bytes, which meets or exceeds the 20 KB limit. Reduce the rendered output before distributing it."
    }

    foreach ($renderedTemplate in $renderedTemplates) {
        [System.IO.File]::WriteAllText($renderedTemplate.Path, $renderedTemplate.Content)
    }
}

$workspaceRoot = "/home/cronjev/.openclaw"
$localAuthToken = Get-DotEnvValue -Path $EnvPath -Name "LOCAL_AUTH_TOKEN"
$headers = @{
    Authorization = "Bearer $localAuthToken"
    Accept        = "application/json"
}

$listUri = "$BaseUrl$AgentsPath"
$agentListResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers
$agentSummaries = ConvertFrom-AgentListResponse -Response $agentListResponse

$agentDetails = @()
$agentById = [ordered]@{}

foreach ($agent in $agentSummaries) {
    $agentId = Get-AgentId -Agent $agent
    $detailUri = "$BaseUrl$AgentsPath/$agentId"
    $agentDetail = Invoke-RestMethod -Method Get -Uri $detailUri -Headers $headers

    $agentDetails += $agentDetail
    $agentById[$agentId] = $agentDetail
}

$result = [pscustomobject]@{
    source = [pscustomobject]@{
        env_path     = $EnvPath
        base_url     = $BaseUrl
        agents_path  = $AgentsPath
        token_name   = "LOCAL_AUTH_TOKEN"
    }
    list = $agentListResponse
    summaries = $agentSummaries
    details = $agentDetails
    by_id = $agentById
}

$result | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $OutputPath

function Render-TemplateContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        $Values
    )

    $rendered = $Content
    foreach ($key in ($Values.Keys | Sort-Object { $_.Length } -Descending)) {
        $replacement = [string]$Values[$key]
        if ([string]::IsNullOrEmpty($replacement)) {
            continue
        }

        $pattern = '\{\{\s*' + [regex]::Escape($key) + '\s*\}\}'
        $rendered = [regex]::Replace(
            $rendered,
            $pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return $replacement
            }
        )
    }

    return $rendered
}

function Render-WorkflowTemplates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetWorkspacePath,
        [Parameter(Mandatory = $true)]
        $Values
    )

    $sourcePath = (Resolve-Path -Path 'backend/simplified-templates/workflow').ProviderPath
    $targetBase = Join-Path $TargetWorkspacePath '.openclaw/workflows'

    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Host "Workflow source path not found: $sourcePath"
        return
    }

    Get-ChildItem -Path $sourcePath -Recurse -File | ForEach-Object {
        $relativePath = $_.FullName.Substring($sourcePath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $targetPath = Join-Path $targetBase $relativePath
        $targetDirectory = Split-Path -Parent $targetPath
        if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        }
        $content = Get-Content -LiteralPath $_.FullName -Raw
        $renderedContent = Render-TemplateContent -Content $content -Values $Values
        [System.IO.File]::WriteAllText($targetPath, $renderedContent)
    }
}
function Render-AgentTemplates {
    param(
        [Parameter(Mandatory = $true)]
        $Detail,
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)]
        [string]$LocalAuthToken,
        [Parameter(Mandatory = $true)]
        [string]$RenderRoot
    )

    $templatePrefix = Get-AgentTemplatePrefix -Detail $Detail
    $workspacePath = Get-AgentWorkspacePath -Detail $Detail -RenderRoot $RenderRoot
    if (-not $workspacePath) {
        Write-Host "Skipping agent '$($Detail.name)' because no render workspace could be resolved."
        return
    }
    $templateValueMap = Get-TemplateValueMap `
        -Detail $Detail `
        -BaseUrl $BaseUrl `
        -AuthToken (Get-StableAgentToken -AgentId ([string]$Detail.id) -LocalAuthToken $LocalAuthToken) `
        -WorkspaceRoot $WorkspaceRoot `
        -WorkspacePath $workspacePath

    Render-WorkspaceTemplates -TemplatePrefix $templatePrefix -TargetWorkspacePath $templateValueMap.WorkspacePath -Values $templateValueMap.Values
    Render-WorkflowTemplates -TargetWorkspacePath $templateValueMap.WorkspacePath -Values $templateValueMap.Values
}

if (-not (Test-Path -LiteralPath $RenderRoot)) {
    New-Item -ItemType Directory -Path $RenderRoot -Force | Out-Null
}

foreach ($detail in $agentDetails) {
    Render-AgentTemplates `
        -Detail $detail `
        -BaseUrl $BaseUrl `
        -WorkspaceRoot $workspaceRoot `
        -LocalAuthToken $localAuthToken `
        -RenderRoot $RenderRoot
}
