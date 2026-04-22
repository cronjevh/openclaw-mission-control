Import-Module (Join-Path $PSScriptRoot 'Api.psm1')

function Test-MconUuidLike {
    param([Parameter(Mandatory)][string]$Value)

    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Resolve-MconTagIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string[]]$Identifiers
    )
    $available = @(Get-MconBoardTags -BaseUrl $BaseUrl -Token $Token -BoardId $BoardId)
    $resolved = @()
    foreach ($id in $Identifiers) {
        if (Test-MconUuidLike -Value $id) {
            $resolved += $id
        } else {
            $lowered = $id.ToLowerInvariant()
            $match = $available | Where-Object { $_.slug.ToLowerInvariant() -eq $lowered -or $_.name.ToLowerInvariant() -eq $lowered } | Select-Object -First 1
            if (-not $match) {
                throw "Tag not found on board: $id"
            }
            $resolved += "$($match.id)"
        }
    }
    return $resolved
}

function Get-MconTagIdentifierList {
    param([Parameter(Mandatory)][string]$Tags)

    return @($Tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-MconNormalizedHeading {
    param([Parameter(Mandatory)][string]$Text)

    return (($Text -replace '[`*_#:\-]+', ' ').Trim().ToLowerInvariant() -replace '\s+', ' ')
}

function Get-MconMarkdownSections {
    param([string]$Markdown)

    $sections = [ordered]@{
        '__preamble' = New-Object System.Collections.Generic.List[string]
    }
    $current = '__preamble'
    $normalized = if ($null -eq $Markdown) { '' } else { $Markdown }
    $normalized = $normalized -replace "`r", ''
    foreach ($line in ($normalized -split "`n")) {
        if ($line -match '^\s{0,3}#{1,6}\s+(.+?)\s*$') {
            $current = Get-MconNormalizedHeading -Text $matches[1]
            if (-not $sections.Contains($current)) {
                $sections[$current] = New-Object System.Collections.Generic.List[string]
            }
            continue
        }
        $sections[$current].Add($line)
    }
    return $sections
}

function Get-MconMarkdownSectionText {
    param(
        [Parameter(Mandatory)]$Sections,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        $key = if ($name -eq '__preamble') { '__preamble' } else { Get-MconNormalizedHeading -Text $name }
        if (-not $Sections.Contains($key)) {
            continue
        }
        $text = (($Sections[$key] -join "`n").Trim())
        if ($text) {
            return $text
        }
    }

    return $null
}

function Get-MconMarkdownListItems {
    param([string]$Text)

    $items = @()
    $normalized = if ($null -eq $Text) { '' } else { $Text }
    foreach ($line in (($normalized -replace "`r", '') -split "`n")) {
        if ($line -match '^\s*[-*+]\s+\[( |x|X)\]\s+(.+?)\s*$') {
            $items += [ordered]@{
                text   = $matches[2].Trim()
                status = if ($matches[1] -match '[xX]') { 'done' } else { 'active' }
            }
            continue
        }
        if ($line -match '^\s*[-*+]\s+(.+?)\s*$') {
            $items += [ordered]@{
                text   = $matches[1].Trim()
                status = 'active'
            }
            continue
        }
        if ($line -match '^\s*\d+\.\s+(.+?)\s*$') {
            $items += [ordered]@{
                text   = $matches[1].Trim()
                status = 'active'
            }
        }
    }
    return $items
}

function Get-MconMarkdownFirstParagraph {
    param([string]$Text)

    $paragraphs = @()
    $current = New-Object System.Collections.Generic.List[string]
    $normalized = if ($null -eq $Text) { '' } else { $Text }
    foreach ($line in (($normalized -replace "`r", '') -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0) {
                $paragraphs += (($current -join ' ').Trim())
                $current.Clear()
            }
            continue
        }
        $current.Add($line.Trim())
    }
    if ($current.Count -gt 0) {
        $paragraphs += (($current -join ' ').Trim())
    }
    return ($paragraphs | Where-Object { $_ } | Select-Object -First 1)
}

function ConvertFrom-MconTagDescriptionMarkdown {
    [CmdletBinding()]
    param([string]$Markdown)

    $sections = Get-MconMarkdownSections -Markdown $Markdown
    $objectiveText = Get-MconMarkdownSectionText -Sections $sections -Names @('objective', 'goal', 'goals')
    $phaseText = Get-MconMarkdownSectionText -Sections $sections -Names @('phase', 'current phase')
    $nextText = Get-MconMarkdownSectionText -Sections $sections -Names @(
        'next recommended task or decision',
        'next recommended task',
        'next step',
        'next task',
        'next decision'
    )
    $krText = Get-MconMarkdownSectionText -Sections $sections -Names @(
        'key results',
        'key result',
        'krs',
        'kr'
    )
    $blockerText = Get-MconMarkdownSectionText -Sections $sections -Names @(
        'blockers',
        'blocker',
        'open blockers',
        'risks'
    )

    if (-not $objectiveText) {
        $objectiveText = (Get-MconMarkdownFirstParagraph -Text (Get-MconMarkdownSectionText -Sections $sections -Names @('__preamble')))
    }
    if (-not $phaseText -and $Markdown -match '(?im)^\s*phase\s*:\s*(.+?)\s*$') {
        $phaseText = $matches[1].Trim()
    }
    if (-not $nextText -and $Markdown -match '(?im)^\s*next(?: recommended task or decision| step| task| decision)?\s*:\s*(.+?)\s*$') {
        $nextText = $matches[1].Trim()
    }

    $activeKrs = @()
    foreach ($item in @(Get-MconMarkdownListItems -Text $krText)) {
        if (-not $item.text) { continue }
        $activeKrs += [ordered]@{
            id          = $null
            description = $item.text
            status      = $item.status
            source      = 'tag_description'
        }
    }
    if ($activeKrs.Count -eq 0) {
        $normalizedMarkdown = if ($null -eq $Markdown) { '' } else { $Markdown }
        foreach ($line in (($normalizedMarkdown -replace "`r", '') -split "`n")) {
            if ($line -match '^\s{0,3}#{1,6}\s*KR\d*\s*[:\-]?\s*(.+?)\s*$') {
                $description = $matches[1].Trim()
                if ($description) {
                    $activeKrs += [ordered]@{
                        id          = $null
                        description = $description
                        status      = 'active'
                        source      = 'tag_description'
                    }
                }
            }
        }
    }

    $blockers = @()
    foreach ($item in @(Get-MconMarkdownListItems -Text $blockerText)) {
        if (-not $item.text) { continue }
        $blockers += [ordered]@{
            id          = $null
            task_id     = $null
            description = $item.text
            owner       = $null
            since       = $null
            status      = 'noted'
            source      = 'tag_description'
        }
    }

    return [ordered]@{
        objective                         = if ($objectiveText) { $objectiveText.Trim() } else { $null }
        phase                             = if ($phaseText) { (Get-MconMarkdownFirstParagraph -Text $phaseText) } else { $null }
        active_krs                        = $activeKrs
        open_blockers                     = $blockers
        next_recommended_task_or_decision = if ($nextText) { (Get-MconMarkdownFirstParagraph -Text $nextText) } else { $null }
        raw_markdown                      = $Markdown
    }
}

function Get-MconDateForSort {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [datetimeoffset]::MinValue
    }
    try {
        return [datetimeoffset]$Value
    }
    catch {
        return [datetimeoffset]::MinValue
    }
}

function Get-MconInferredPhase {
    param($Tasks)

    $allTasks = @($Tasks)
    if ($allTasks.Count -eq 0) {
        return 'foundation'
    }

    $doneCount = @($allTasks | Where-Object { $_.status -eq 'done' }).Count
    $ratio = $doneCount / $allTasks.Count
    if ($ratio -lt 0.3) {
        return 'implementation'
    }
    if ($ratio -lt 0.8) {
        return 'validation'
    }
    return 'closure'
}

function Get-MconFallbackKrs {
    param($Tasks)

    $items = @()
    foreach ($task in @($Tasks | Where-Object { $_.title -match 'KR|Key Result' })) {
        $items += [ordered]@{
            id          = "$($task.id)"
            description = "$($task.title)"
            status      = if ($task.status -eq 'done') { 'done' } else { 'active' }
            source      = 'board_task'
        }
    }
    return $items
}

function Get-MconNextRecommendedTask {
    param($Tasks)

    $ordered = @(
        @($Tasks | Where-Object { $_.status -eq 'inbox' } | Sort-Object { Get-MconDateForSort $_.created_at }) +
        @($Tasks | Where-Object { $_.status -eq 'in_progress' } | Sort-Object { Get-MconDateForSort $_.created_at }) +
        @($Tasks | Where-Object { $_.status -eq 'review' } | Sort-Object { Get-MconDateForSort $_.created_at })
    )
    $first = $ordered | Select-Object -First 1
    if (-not $first) {
        return $null
    }
    return "Continue current workstream; next focus: $($first.title)"
}

function Resolve-MconProjectTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string[]]$Identifiers
    )

    $available = @(Get-MconBoardTags -BaseUrl $BaseUrl -Token $Token -BoardId $BoardId)
    $ordered = @()

    foreach ($identifier in $Identifiers) {
        $matches = @()
        if (Test-MconUuidLike -Value $identifier) {
            $matches = @($available | Where-Object { "$($_.id)" -eq $identifier })
        } else {
            $lowered = $identifier.ToLowerInvariant()
            $matches = @($available | Where-Object {
                $_.slug.ToLowerInvariant() -eq $lowered -or $_.name.ToLowerInvariant() -eq $lowered
            })
        }

        if ($matches.Count -eq 0) {
            throw "Tag not found on board: $identifier"
        }
        if ($matches.Count -gt 1) {
            throw "Tag identifier is ambiguous on this board: $identifier"
        }

        $match = $matches[0]
        $matchId = "$($match.id)"
        if (@($ordered | Where-Object { "$($_.id)" -eq $matchId }).Count -gt 0) {
            continue
        }
        $ordered += [pscustomobject]@{
            id          = $match.id
            name        = $match.name
            slug        = $match.slug
            color       = $match.color
            description = $null
            task_count  = 0
        }
    }

    return $ordered
}

function Get-MconProjectTagSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tag,
        [Parameter(Mandatory)]$Tasks
    )

    $parsed = ConvertFrom-MconTagDescriptionMarkdown -Markdown $Tag.description
    $allTasks = @($Tasks)
    $generatedAt = [DateTimeOffset]::UtcNow.ToString('o')

    $activeTasks = @(
        $allTasks |
        Where-Object { $_.status -in @('inbox', 'in_progress', 'review') } |
        Sort-Object { Get-MconDateForSort $_.created_at }
    )
    $doneTasks = @(
        $allTasks |
        Where-Object { $_.status -eq 'done' } |
        Sort-Object @{ Expression = { Get-MconDateForSort $_.updated_at }; Descending = $true }
    )
    $boardBlockers = @()
    foreach ($task in @($allTasks | Where-Object {
        $_.status -eq 'blocked' -or $_.is_blocked -or @($_.blocked_by_task_ids).Count -gt 0
    })) {
        $boardBlockers += [ordered]@{
            id             = "$($task.id)"
            task_id        = "$($task.id)"
            description    = "$($task.title)"
            owner          = if ($task.assigned_agent_id) { "$($task.assigned_agent_id)" } else { $null }
            since          = if ($task.created_at) { "$($task.created_at)" } else { $null }
            status         = if ($task.status) { "$($task.status)" } else { 'blocked' }
            blocked_by_ids = @($task.blocked_by_task_ids | ForEach-Object { "$_" })
            source         = 'board_task'
        }
    }

    $activeKrs = @($parsed.active_krs)
    if ($activeKrs.Count -eq 0) {
        $activeKrs = @(Get-MconFallbackKrs -Tasks $allTasks)
    }

    return [ordered]@{
        ledger_version                    = 'board-derived-1'
        project_tag                       = "$($Tag.slug)"
        project_slug                      = "$($Tag.slug)"
        tag                               = [ordered]@{
            id          = "$($Tag.id)"
            name        = "$($Tag.name)"
            slug        = "$($Tag.slug)"
            color       = "$($Tag.color)"
            description = $Tag.description
            task_count  = $Tag.task_count
        }
        objective                         = if ($parsed.objective) { $parsed.objective } else { "Tag workstream: $($Tag.name)" }
        phase                             = if ($parsed.phase) { $parsed.phase } else { Get-MconInferredPhase -Tasks $allTasks }
        active_krs                        = $activeKrs
        open_blockers                     = @($parsed.open_blockers) + $boardBlockers
        active_related_tasks              = @(
            $activeTasks | ForEach-Object {
                [ordered]@{
                    task_id  = "$($_.id)"
                    title    = "$($_.title)"
                    status   = "$($_.status)"
                    assignee = if ($_.assigned_agent_id) { "$($_.assigned_agent_id)" } else { $null }
                }
            }
        )
        active_task_ids                   = @($activeTasks | ForEach-Object { "$($_.id)" })
        last_reviewed_artifacts           = @(
            $doneTasks |
            Select-Object -First 5 |
            ForEach-Object {
                [ordered]@{
                    task_id      = "$($_.id)"
                    title        = "$($_.title)"
                    completed_at = if ($_.updated_at) { "$($_.updated_at)" } else { $null }
                }
            }
        )
        next_recommended_task_or_decision = if ($parsed.next_recommended_task_or_decision) {
            $parsed.next_recommended_task_or_decision
        } else {
            Get-MconNextRecommendedTask -Tasks $activeTasks
        }
        tag_description_markdown          = $Tag.description
        generated_at                      = $generatedAt
        last_synced_at                    = $generatedAt
        last_synced_from_board            = $true
    }
}

function Get-MconProjectTagSummaries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string[]]$TagIdentifiers
    )

    $resolvedTags = @(Resolve-MconProjectTags -BaseUrl $BaseUrl -Token $Token -BoardId $BoardId -Identifiers $TagIdentifiers)
    $summaries = @()
    foreach ($tag in $resolvedTags) {
        $tagSlug = [string]$tag.slug
        if ([string]::IsNullOrWhiteSpace($tagSlug)) {
            throw "Resolved tag is missing a slug."
        }
        $tasks = @(Get-MconBoardTasks -BaseUrl $BaseUrl -Token $Token -BoardId $BoardId -Tag $tagSlug -IncludeHiddenDone:$true)
        $summaries += Get-MconProjectTagSummary -Tag $tag -Tasks $tasks
    }

    return [ordered]@{
        generated_at   = [DateTimeOffset]::UtcNow.ToString('o')
        requested_tags = @($TagIdentifiers)
        summaries      = $summaries
    }
}

Export-ModuleMember -Function Get-MconTagIdentifierList, Resolve-MconTagIds, Get-MconProjectTagSummaries
