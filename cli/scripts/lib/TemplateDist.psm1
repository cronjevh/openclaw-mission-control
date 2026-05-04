function ConvertFrom-MconAgentListResponse {
    param([Parameter(Mandatory)]$Response)

    if ($Response -is [System.Collections.IEnumerable] -and $Response -isnot [string]) {
        return @($Response)
    }

    foreach ($prop in @('agents', 'items', 'data', 'results')) {
        $value = $Response.$prop
        if ($null -ne $value) { return @($value) }
    }

    throw "Unrecognized agent list response shape."
}

function Get-MconAgentId {
    param([Parameter(Mandatory)]$Agent)

    foreach ($prop in @('id', 'agent_id', 'agentId')) {
        $value = $Agent.$prop
        if ($value) { return [string]$value }
    }

    throw "Agent record does not include an id field."
}

function Get-MconAgentResolvedRole {
    param([Parameter(Mandatory)]$Detail)

    if ($Detail.identity_profile -and $Detail.identity_profile.PSObject.Properties['role']) {
        $value = [string]$Detail.identity_profile.role
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }

    if ($Detail.PSObject.Properties['role']) {
        $value = [string]$Detail.role
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }

    return $null
}

function Test-MconIsVerifierRole {
    param([string]$Role)

    if ([string]::IsNullOrWhiteSpace($Role)) { return $false }
    return $Role.Trim().Equals('verifier', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-MconAgentRenderRole {
    param([Parameter(Mandatory)]$Detail)

    $isLead = $false
    if ($Detail.PSObject.Properties['is_board_lead']) { $isLead = [bool]$Detail.is_board_lead }
    if (-not $isLead -and $Detail.PSObject.Properties['is_gateway_main']) { $isLead = [bool]$Detail.is_gateway_main }

    if ($isLead) { return 'lead' }

    $resolvedRole = Get-MconAgentResolvedRole -Detail $Detail
    if (Test-MconIsVerifierRole -Role $resolvedRole) { return 'verifier' }

    return 'worker'
}

function Get-MconAgentTemplatePrefix {
    param([Parameter(Mandatory)]$Detail)

    $isLead = $false
    if ($Detail.PSObject.Properties['is_board_lead']) { $isLead = [bool]$Detail.is_board_lead }
    if (-not $isLead -and $Detail.PSObject.Properties['is_gateway_main']) { $isLead = [bool]$Detail.is_gateway_main }

    if ($isLead) { return 'BOARD_LEAD_' }

    $resolvedRole = Get-MconAgentResolvedRole -Detail $Detail
    if (Test-MconIsVerifierRole -Role $resolvedRole) { return 'BOARD_VERIFIER_' }

    return 'BOARD_WORKER_'
}

function Get-MconAgentWorkspacePath {
    param(
        [Parameter(Mandatory)]$Detail,
        [Parameter(Mandatory)][string]$RenderRoot
    )

    $isLead = $false
    if ($Detail.PSObject.Properties['is_board_lead']) { $isLead = [bool]$Detail.is_board_lead }
    if (-not $isLead -and $Detail.PSObject.Properties['is_gateway_main']) { $isLead = [bool]$Detail.is_gateway_main }

    if ($isLead) {
        if (-not $Detail.board_id) { return $null }
        return Join-Path $RenderRoot "workspace-lead-$([string]$Detail.board_id)"
    }

    if (-not $Detail.id) { throw "Agent '$($Detail.name)' is missing id." }

    return Join-Path $RenderRoot "workspace-mc-$([string]$Detail.id)"
}

function Get-MconTemplateValueMap {
    param(
        [Parameter(Mandatory)]$Detail,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $map = [ordered]@{}

    $map.base_url = $BaseUrl
    $map.auth_token = $AuthToken
    $map.workspace_root = $WorkspaceRoot
    $map.workspace_path = $WorkspacePath
    $map.agent_render_role = Get-MconAgentRenderRole -Detail $Detail
    $map.board_id = [string]$Detail.board_id
    $map.name = [string]$Detail.name
    $map.id = [string]$Detail.id
    $resolvedRole = Get-MconAgentResolvedRole -Detail $Detail
    $map['identity_profile.role'] = $resolvedRole

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

    foreach ($propName in @(
        'gateway_id', 'group_id', 'is_board_lead', 'is_gateway_main',
        'openclaw_session_id', 'identity_template', 'soul_template',
        'last_seen_at', 'created_at', 'updated_at'
    )) {
        $value = $Detail.$propName
        if ($null -ne $value) {
            $map[$propName] = [string]$value
        }
    }

    return [pscustomobject]@{
        Values        = $map
        WorkspacePath = $WorkspacePath
    }
}

function Convert-MconTemplateContent {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)]$Values
    )

    $rendered = $Content
    foreach ($key in ($Values.Keys | Sort-Object { $_.Length } -Descending)) {
        $replacement = [string]$Values[$key]
        if ([string]::IsNullOrEmpty($replacement)) { continue }

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

function ConvertFrom-MconTemplateContent {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)]$Values
    )

    $rendered = $Content
    $keys = $Values.Keys | Where-Object {
        $value = [string]$Values[$_]
        -not [string]::IsNullOrEmpty($value)
    } | Sort-Object { ([string]$Values[$_]).Length } -Descending

    foreach ($key in $keys) {
        $value = [string]$Values[$key]
        $placeholder = "{{ $key }}"
        $escapedValue = [regex]::Escape($value)
        $rendered = [regex]::Replace(
            $rendered,
            $escapedValue,
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return $placeholder
            }
        )
    }

    return $rendered
}

function Publish-MconWorkspaceTemplates {
    param(
        [Parameter(Mandatory)][string]$TemplatePrefix,
        [Parameter(Mandatory)][string]$TargetWorkspacePath,
        [Parameter(Mandatory)]$Values,
        [Parameter(Mandatory)][string]$TemplatesDir
    )

    $templateFiles = Get-ChildItem -LiteralPath $TemplatesDir -Filter "$TemplatePrefix*.md" -File | Sort-Object Name
    $templatePerFileLimitBytes = 30KB
    $templateBundleLimitBytes = 70KB
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
        $renderedContent = Convert-MconTemplateContent -Content $templateContent -Values $Values

        if ($null -ne $existingContent -and -not $existingContent.EndsWith("`n")) {
            $renderedContent = $renderedContent -replace '\r?\n\z', ''
        } elseif ($null -ne $existingContent -and -not $renderedContent.EndsWith("`n")) {
            $renderedContent += "`n"
        }

        $renderedContentBytes = [System.Text.Encoding]::UTF8.GetByteCount($renderedContent)
        if ($renderedContentBytes -ge $templatePerFileLimitBytes) {
            throw "Rendered template '$targetFileName' for '$TemplatePrefix' is $renderedContentBytes bytes, which meets or exceeds the 17 KB per-file limit. Reduce the rendered output before distributing it."
        }

        $renderedBytes += $renderedContentBytes
        $renderedTemplates += [pscustomobject]@{
            Path    = $targetPath
            Content = $renderedContent
        }
    }

    if ($renderedBytes -ge $templateBundleLimitBytes) {
        throw "Rendered template bundle for '$TemplatePrefix' is $renderedBytes bytes, which meets or exceeds the 40 KB bundle limit. Reduce the rendered output before distributing it."
    }

    foreach ($renderedTemplate in $renderedTemplates) {
        [System.IO.File]::WriteAllText($renderedTemplate.Path, $renderedTemplate.Content)
    }

    return $renderedTemplates.Count
}

function Publish-MconWorkflowTemplates {
    param(
        [Parameter(Mandatory)][string]$TargetWorkspacePath,
        [Parameter(Mandatory)]$Values,
        [Parameter(Mandatory)][string]$TemplatesDir
    )

    $workflowSourcePath = Join-Path $TemplatesDir 'workflow'
    if (-not (Test-Path -LiteralPath $workflowSourcePath)) {
        return 0
    }

    $targetBase = Join-Path $TargetWorkspacePath '.openclaw/workflows'
    $count = 0

    Get-ChildItem -LiteralPath $workflowSourcePath -Recurse -File | ForEach-Object {
        $relativePath = $_.FullName.Substring($workflowSourcePath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $targetPath = Join-Path $targetBase $relativePath
        $targetDirectory = Split-Path -Parent $targetPath
        if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        }
        $content = Get-Content -LiteralPath $_.FullName -Raw
        $renderedContent = Convert-MconTemplateContent -Content $content -Values $Values
        [System.IO.File]::WriteAllText($targetPath, $renderedContent)
        $count++
    }

    return $count
}

function Restore-MconWorkspaceTemplates {
    param(
        [Parameter(Mandatory)][string]$TemplatePrefix,
        [Parameter(Mandatory)][string]$SourceWorkspacePath,
        [Parameter(Mandatory)]$Values,
        [Parameter(Mandatory)][string]$TemplatesDir
    )

    $templateFiles = Get-ChildItem -LiteralPath $TemplatesDir -Filter "$TemplatePrefix*.md" -File | Sort-Object Name
    $count = 0

    foreach ($templateFile in $templateFiles) {
        $workspaceFileName = $templateFile.Name -replace ('^' + [regex]::Escape($TemplatePrefix)), ''
        $workspaceFilePath = Join-Path $SourceWorkspacePath $workspaceFileName
        if (-not (Test-Path -LiteralPath $workspaceFilePath)) { continue }

        $workspaceContent = Get-Content -LiteralPath $workspaceFilePath -Raw
        $templateContent = ConvertFrom-MconTemplateContent -Content $workspaceContent -Values $Values
        [System.IO.File]::WriteAllText($templateFile.FullName, $templateContent)
        $count++
    }

    return $count
}

function Invoke-MconTemplateDist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalAuthToken,
        [string]$BaseUrl = 'http://localhost:8002',
        [string]$AgentsPath = '/api/v1/agents',
        [string]$RenderRoot = '/home/cronjev/.openclaw',
        [string]$TemplatesDir,
        [string]$OutputPath,
        [string[]]$ReverseRenderAgentNames = @(),
        [switch]$ReverseRender
    )

    if (-not $TemplatesDir) {
        throw 'TemplatesDir is required. Provide the path to the simplified-templates directory via --templates-dir.'
    }
    if (-not (Test-Path -LiteralPath $TemplatesDir)) {
        throw "Templates directory not found: $TemplatesDir"
    }

    $workspaceRoot = '/home/cronjev/.openclaw'

    $bearerHeaders = @{
        Authorization = "Bearer $LocalAuthToken"
        Accept        = 'application/json'
    }

    $listUri = "$BaseUrl$AgentsPath"
    $agentListResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $bearerHeaders -TimeoutSec 30
    $agentSummaries = ConvertFrom-MconAgentListResponse -Response $agentListResponse

    $agentDetails = @()
    $agentById = [ordered]@{}

    foreach ($agent in $agentSummaries) {
        $agentId = Get-MconAgentId -Agent $agent
        $detailUri = "$BaseUrl$AgentsPath/$agentId"
        $agentDetail = Invoke-RestMethod -Method Get -Uri $detailUri -Headers $bearerHeaders -TimeoutSec 30

        $agentDetails += $agentDetail
        $agentById[$agentId] = $agentDetail
    }

    if ($OutputPath) {
        $snapshot = [pscustomobject]@{
            source    = [pscustomobject]@{
                base_url    = $BaseUrl
                agents_path = $AgentsPath
            }
            summaries = $agentSummaries
            details   = $agentDetails
            by_id     = $agentById
        }
        $snapshot | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }

    if (-not (Test-Path -LiteralPath $RenderRoot)) {
        New-Item -ItemType Directory -Path $RenderRoot -Force | Out-Null
    }

    $results = @()
    $workspaceRootVal = $workspaceRoot

    foreach ($detail in $agentDetails) {
        if ($ReverseRender) {
            if ($ReverseRenderAgentNames.Count -gt 0 -and $detail.name -notin $ReverseRenderAgentNames) {
                continue
            }

            $templatePrefix = Get-MconAgentTemplatePrefix -Detail $detail
            $workspacePath = Get-MconAgentWorkspacePath -Detail $detail -RenderRoot $RenderRoot
            if (-not $workspacePath -or -not (Test-Path -LiteralPath $workspacePath)) { continue }

            $templateValueMap = Get-MconTemplateValueMap `
                -Detail $detail `
                -BaseUrl $BaseUrl `
                -AuthToken (Get-StableAgentToken -AgentId ([string]$detail.id) -LocalAuthToken $LocalAuthToken) `
                -WorkspaceRoot $workspaceRootVal `
                -WorkspacePath $workspacePath

            $count = Restore-MconWorkspaceTemplates `
                -TemplatePrefix $templatePrefix `
                -SourceWorkspacePath $templateValueMap.WorkspacePath `
                -Values $templateValueMap.Values `
                -TemplatesDir $TemplatesDir

            $results += [ordered]@{
                agent_name     = $detail.name
                agent_id       = [string]$detail.id
                render_role    = Get-MconAgentRenderRole -Detail $detail
                workspace_path = $workspacePath
                files_updated  = $count
                direction      = 'reverse'
            }
            continue
        }

        $templatePrefix = Get-MconAgentTemplatePrefix -Detail $detail
        $workspacePath = Get-MconAgentWorkspacePath -Detail $detail -RenderRoot $RenderRoot
        if (-not $workspacePath) {
            $results += [ordered]@{
                agent_name     = $detail.name
                agent_id       = [string]$detail.id
                render_role    = Get-MconAgentRenderRole -Detail $detail
                workspace_path = $null
                files_updated  = 0
                direction      = 'forward'
                skipped        = $true
                skip_reason    = 'no_workspace_resolved'
            }
            continue
        }

        $templateValueMap = Get-MconTemplateValueMap `
            -Detail $detail `
            -BaseUrl $BaseUrl `
            -AuthToken (Get-StableAgentToken -AgentId ([string]$detail.id) -LocalAuthToken $LocalAuthToken) `
            -WorkspaceRoot $workspaceRootVal `
            -WorkspacePath $workspacePath

        $wsCount = Publish-MconWorkspaceTemplates `
            -TemplatePrefix $templatePrefix `
            -TargetWorkspacePath $templateValueMap.WorkspacePath `
            -Values $templateValueMap.Values `
            -TemplatesDir $TemplatesDir

        $wfCount = Publish-MconWorkflowTemplates `
            -TargetWorkspacePath $templateValueMap.WorkspacePath `
            -Values $templateValueMap.Values `
            -TemplatesDir $TemplatesDir

        $results += [ordered]@{
            agent_name     = $detail.name
            agent_id       = [string]$detail.id
            render_role    = Get-MconAgentRenderRole -Detail $detail
            workspace_path = $workspacePath
            files_updated  = $wsCount + $wfCount
            direction      = 'forward'
        }
    }

    return [ordered]@{
        ok              = $true
        agent_count     = $agentDetails.Count
        results         = $results
        output_path     = $OutputPath
        templates_dir   = $TemplatesDir
        render_root     = $RenderRoot
        direction       = if ($ReverseRender) { 'reverse' } else { 'forward' }
    }
}

Export-ModuleMember -Function Invoke-MconTemplateDist
