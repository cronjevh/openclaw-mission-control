param(
    [string]$EnvPath = "backend/.env",
    [string]$BaseUrl = "http://localhost:8002",
    [string]$AgentsPath = "/api/v1/agents",
    [string]$OutputPath = "backend/simplified-templates/template-update.json"
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
        [string]$WorkspaceRoot
    )

    $map = [ordered]@{}
    $workspacePath = Join-Path $WorkspaceRoot "workspace-mc-$($Detail.id)"

    $map.base_url = $BaseUrl
    $map.auth_token = $AuthToken
    $map.workspace_root = $WorkspaceRoot
    $map.workspace_path = $workspacePath
    $map.board_id = [string]$Detail.board_id
    $map.name = [string]$Detail.name
    $map.id = [string]$Detail.id
    $map["identity_profile.role"] = "analyst/architect/tech-writer agent"

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
        WorkspacePath = $workspacePath
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

$detail = $result.list.items.Where({ $_.name -eq 'Athena' }) | Select-Object -First 1
if (-not $detail) {
    throw "Could not find the Athena agent in the fetched agent list."
}

$templateValueMap = Get-TemplateValueMap -Detail $detail -BaseUrl $BaseUrl -AuthToken (Get-StableAgentToken -AgentId ([string]$detail.id) -LocalAuthToken $localAuthToken) -WorkspaceRoot $workspaceRoot
$templateFiles = Get-ChildItem -Path 'backend/simplified-templates' -Filter 'BOARD_WORKER_*.md' -File | Sort-Object Name

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

foreach ($templateFile in $templateFiles) {
    $targetFileName = $templateFile.Name -replace '^BOARD_WORKER_', ''
    $targetPath = Join-Path $templateValueMap.WorkspacePath $targetFileName
    $existingContent = if (Test-Path -LiteralPath $targetPath) {
        Get-Content -LiteralPath $targetPath -Raw
    } else {
        $null
    }
    $templateContent = Get-Content -LiteralPath $templateFile.FullName -Raw
    $renderedContent = Render-TemplateContent -Content $templateContent -Values $templateValueMap.Values

    if ($null -ne $existingContent -and -not $existingContent.EndsWith("`n")) {
        $renderedContent = $renderedContent -replace '\r?\n\z', ''
    } elseif ($null -ne $existingContent -and -not $renderedContent.EndsWith("`n")) {
        $renderedContent += "`n"
    }

    [System.IO.File]::WriteAllText($targetPath, $renderedContent)
}
