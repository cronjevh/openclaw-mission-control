function Test-MconVerificationTaskLooksLikeDocs {
    param(
        [Parameter(Mandatory)]$Task
    )

    $title = if ($Task.PSObject.Properties.Name -contains 'title') { [string]$Task.title } else { '' }
    $description = if ($Task.PSObject.Properties.Name -contains 'description') { [string]$Task.description } else { '' }
    $text = "$title`n$description"

    # Explicit task_class override: design_exploratory and docs_content are always docs-like
    if ($Task.PSObject.Properties.Name -contains 'task_class') {
        $tc = [string]$Task.task_class
        if ($tc -in @('docs_content', 'design_exploratory')) {
            return $true
        }
    }

    return $text -match '(?i)\b(plan|planning|document|documentation|note|strategy|report|analysis)\b'
}

function Get-MconVerifyTaskBundlePaths {
    param(
        [Parameter(Mandatory)][string]$LeadWorkspacePath,
        [Parameter(Mandatory)][string]$TaskId
    )

    $taskDirectory = Join-Path $LeadWorkspacePath "tasks/$TaskId"
    $deliverablesDirectory = Join-Path $taskDirectory 'deliverables'
    $evidenceDirectory = Join-Path $taskDirectory 'evidence'

    return [ordered]@{
        task_directory = $taskDirectory
        deliverables_directory = $deliverablesDirectory
        evidence_directory = $evidenceDirectory
    }
}

function Get-MconVerificationCandidateDeliverables {
    param(
        [Parameter(Mandatory)][string]$DeliverablesDirectory,
        [Parameter(Mandatory)][string]$TaskId
    )

    if (-not (Test-Path -LiteralPath $DeliverablesDirectory)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $DeliverablesDirectory -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ne "verify-$TaskId.ps1" -and
                $_.Name -ne "evaluate-$TaskId.json"
            }
    )
}

function Test-MconDeliverableLooksLikeImplementation {
    param(
        [Parameter(Mandatory)]$File
    )

    $name = $File.Name.ToLowerInvariant()
    if (
        $name -match '(^|[-_])(readme|deployment|handoff|notes?|summary|report|plan|analysis)($|[-_.])' -or
        $name -like '*.md' -or
        $name -like '*.patch' -or
        $name -like '*.diff' -or
        $name -match '(^|[-_])(smoke|demo|sample|example|fixture|mock|test)($|[-_.])'
    ) {
        return $false
    }

    return $true
}

function Get-MconPrimaryDeliverablePath {
    param(
        [Parameter(Mandatory)][string]$DeliverablesDirectory,
        [Parameter(Mandatory)][string]$TaskId
    )

    $files = @(Get-MconVerificationCandidateDeliverables -DeliverablesDirectory $DeliverablesDirectory -TaskId $TaskId)

    if ($files.Count -eq 0) {
        throw "Primary deliverable not found in $DeliverablesDirectory"
    }

    $ranked = @(
        $files |
            Sort-Object `
                @{ Expression = { if (Test-MconDeliverableLooksLikeImplementation -File $_) { 1 } else { 0 } }; Descending = $true }, `
                @{ Expression = { $_.Length }; Descending = $true }, `
                @{ Expression = { $_.Name.Length }; Descending = $false }, `
                @{ Expression = { $_.Name }; Descending = $false }
    )

    return $ranked[0].FullName
}

function Test-MconVerificationTaskLooksLikeIntegration {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$ImplementationFiles
    )

    $title = if ($Task.PSObject.Properties.Name -contains 'title') { [string]$Task.title } else { '' }
    $description = if ($Task.PSObject.Properties.Name -contains 'description') { [string]$Task.description } else { '' }
    $text = "$title`n$description"

    if ($ImplementationFiles.Count -gt 1) {
        return $true
    }

    return $text -match '(?i)\b(api|queue|worker|webhook|cron|crontab|scheduler|cadence|dispatch|automation|integration|service|daemon|watcher)\b'
}

function Test-MconVerificationTaskLooksLikeWorkspaceConfig {
    param(
        [Parameter(Mandatory)]$Task
    )

    # Check explicit task_class first
    if ($Task.PSObject.Properties.Name -contains 'task_class' -and $Task.task_class -eq 'workspace_config') {
        return $true
    }

    $title = if ($Task.PSObject.Properties.Name -contains 'title') { [string]$Task.title } else { '' }
    $description = if ($Task.PSObject.Properties.Name -contains 'description') { [string]$Task.description } else { '' }
    $text = "$title`n$description"

    return $text -match '(?i)\b(AGENTS\.md|SOUL\.md|HEARTBEAT\.md|TOOLS\.md|workspace|prompt|guideline|instruction|policy)\b'
}

function Get-MconVerificationProfilesConfig {
    param(
        [string]$ConfigPath = $null
    )

    if (-not $ConfigPath) {
        # PSScriptRoot is cli/scripts/lib; go up two levels to cli/
        $scriptDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $ConfigPath = Join-Path $scriptDir 'config/verification-profiles.json'
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 10
        return $raw
    } catch {
        Write-Warning "Failed to load verification profiles from $ConfigPath : $_"
        return $null
    }
}

function Get-MconVerificationProfileForTask {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $profiles = $Config.profiles
    $defaultProfile = $Config.default_profile
    if (-not $profiles) {
        return $defaultProfile
    }

    $taskClass = if ($Task.PSObject.Properties.Name -contains 'task_class') { [string]$Task.task_class } else { '' }
    $title = if ($Task.PSObject.Properties.Name -contains 'title') { [string]$Task.title } else { '' }
    $description = if ($Task.PSObject.Properties.Name -contains 'description') { [string]$Task.description } else { '' }
    $text = "$title`n$description"

    # Match by task_class first
    foreach ($profileName in $profiles.Keys) {
        $profile = $profiles[$profileName]
        $detection = $profile.detection
        if ($detection -and $detection.task_class) {
            if ($taskClass -in $detection.task_class) {
                return $profile
            }
        }
    }

    # Fallback to keyword matching
    foreach ($profileName in $profiles.Keys) {
        $profile = $profiles[$profileName]
        $detection = $profile.detection
        if ($detection -and $detection.keywords) {
            foreach ($keyword in $detection.keywords) {
                if ($text -match [regex]::Escape($keyword)) {
                    return $profile
                }
            }
        }
    }

    return $defaultProfile
}

function Merge-MconVerificationProfile {
    param(
        [Parameter(Mandatory)][hashtable]$Profile,
        [hashtable]$TaskRules = $null
    )

    $merged = @{}

    # Start with profile preflight rules
    if ($Profile.preflight) {
        foreach ($key in $Profile.preflight.Keys) {
            $merged[$key] = $Profile.preflight[$key]
        }
    }

    # Overlay task-level verification_rules overrides
    if ($TaskRules -and $TaskRules.preflight) {
        foreach ($key in $TaskRules.preflight.Keys) {
            $merged[$key] = $TaskRules.preflight[$key]
        }
    }

    # Collect required patterns from profile + task override
    $requiredPatterns = [System.Collections.ArrayList]::new()
    if ($Profile.required_patterns) {
        [void]$requiredPatterns.AddRange($Profile.required_patterns)
    }
    if ($TaskRules -and $TaskRules.required_patterns) {
        [void]$requiredPatterns.AddRange($TaskRules.required_patterns)
    }

    # Collect forbidden patterns from profile + task override
    $forbiddenPatterns = [System.Collections.ArrayList]::new()
    if ($Profile.forbidden_patterns) {
        [void]$forbiddenPatterns.AddRange($Profile.forbidden_patterns)
    }
    if ($TaskRules -and $TaskRules.forbidden_patterns) {
        [void]$forbiddenPatterns.AddRange($TaskRules.forbidden_patterns)
    }

    return [ordered]@{
        preflight = $merged
        required_patterns = @($requiredPatterns)
        forbidden_patterns = @($forbiddenPatterns)
        notes = if ($Profile.notes) { $Profile.notes } else { '' }
    }
}

function Test-MconVerificationPreflight {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$VerificationPaths,
        [Parameter(Mandatory)]$TaskBundlePaths
    )

    # ============================================================
    # Dynamic Verification Profile System
    # ============================================================
    # Profiles are loaded from cli/config/verification-profiles.json.
    # Tasks may override profile behavior via the verification_rules field.
    # When no profile matches, hardcoded detection functions provide fallback.
    # ============================================================

    $verificationArtifactPath = $VerificationPaths.verification_artifact_path
    $deliverables = @(Get-MconVerificationCandidateDeliverables -DeliverablesDirectory $TaskBundlePaths.deliverables_directory -TaskId $Task.id)
    $implementationFiles = @($deliverables | Where-Object { Test-MconDeliverableLooksLikeImplementation -File $_ })
    $scriptContent = Get-Content -LiteralPath $verificationArtifactPath -Raw
    $reasons = @()
    $notes = @()

    # Load dynamic profile configuration
    $profilesConfig = Get-MconVerificationProfilesConfig
    $taskRules = $null
    if ($Task.PSObject.Properties.Name -contains 'verification_rules' -and $Task.verification_rules) {
        try {
            if ($Task.verification_rules -is [hashtable]) {
                $taskRules = $Task.verification_rules
            } elseif ($Task.verification_rules -is [pscustomobject]) {
                $taskRules = @{}
                $Task.verification_rules.PSObject.Properties | ForEach-Object {
                    $taskRules[$_.Name] = $_.Value
                }
            }
        } catch {
            $notes += "Task has verification_rules but could not parse them"
        }
    }

    $matchedProfile = $null
    $mergedRules = $null
    if ($profilesConfig) {
        $matchedProfile = Get-MconVerificationProfileForTask -Task $Task -Config $profilesConfig
        $mergedRules = Merge-MconVerificationProfile -Profile $matchedProfile -TaskRules $taskRules
        if ($matchedProfile.notes) {
            $notes += $matchedProfile.notes
        }
    }

    $workspaceConfigLike = Test-MconVerificationTaskLooksLikeWorkspaceConfig -Task $Task
    if ($workspaceConfigLike) {
        $notes += "Detected workspace config task (content checks are valid)"
    }

    $mentionedDeliverables = @(
        $deliverables |
            Where-Object { $scriptContent -match [regex]::Escape($_.Name) } |
            Select-Object -ExpandProperty Name -Unique
    )
    $mentionedImplementationFiles = @(
        $implementationFiles |
            Where-Object { $scriptContent -match [regex]::Escape($_.Name) } |
            Select-Object -ExpandProperty Name -Unique
    )

    # Deliverable-by-filename check (skippable via profile)
    $skipDeliverableCheck = $mergedRules -and $mergedRules.preflight.skip_deliverable_by_filename
    if ($mentionedDeliverables.Count -eq 0 -and -not $workspaceConfigLike -and -not $skipDeliverableCheck) {
        $reasons += 'Verification script does not reference any non-verification deliverable by filename.'
    }

    if ($implementationFiles.Count -gt 0 -and $mentionedImplementationFiles.Count -eq 0 -and -not $workspaceConfigLike -and -not $skipDeliverableCheck) {
        $implNames = @($implementationFiles | Select-Object -ExpandProperty Name)
        $reasons += "Verification script does not target implementation deliverables directly: $($implNames -join ', ')"
    }

    $hasSuccessExit = $scriptContent -match '(?mi)^\s*exit\s+0\s*$' -or $scriptContent -match '(?mi)^\s*return\s+0\s*$'
    $hasFailureExit = $scriptContent -match '(?mi)^\s*exit\s+1\s*$' -or
        $scriptContent -match '(?mi)^\s*exit\s+\$[A-Za-z_][A-Za-z0-9_]*\s*$' -or
        $scriptContent -match '(?mi)^\s*return\s+1\s*$'
    $requireExitPaths = if ($mergedRules -and $mergedRules.preflight.ContainsKey('require_exit_paths')) { $mergedRules.preflight.require_exit_paths } else { $true }
    if ($hasSuccessExit -and -not $hasFailureExit -and $requireExitPaths) {
        $reasons += 'Verification script contains a success-only exit path.'
    }

    $runtimeSignals = @(
        '(?i)\bpytest\b',
        '(?i)\bpython(\d+(\.\d+)*)?\b',
        '(?i)\buv\s+run\b',
        '(?i)\bnode\b',
        '(?i)\bnpm\b',
        '(?i)\bpnpm\b',
        '(?i)\byarn\b',
        '(?i)\bdotnet\b',
        '(?i)\bgo\s+test\b',
        '(?i)\bcargo\s+test\b',
        '(?i)\binvoke-restmethod\b',
        '(?i)\bcurl\b',
        '(?i)\bdocker\b',
        '(?i)\bbash\b',
        '(?i)\bsh\b',
        '(?i)Start-Process',
        '(?i)&\s*\$[A-Za-z_][A-Za-z0-9_]*',
        '(?i)&\s*["''][^"'']+\.(ps1|py|sh|bash|js|ts)',
        '(?i)&\s*pwsh\s+-File',
        '(?i)&\s*powershell\s+-File'
    )
    $runtimeSignalCount = 0
    foreach ($pattern in $runtimeSignals) {
        if ($scriptContent -match $pattern) {
            $runtimeSignalCount++
        }
    }

    $hasSelfTest = $scriptContent -match '(?i)-SelfTest\b'
    $requireSelfTest = if ($mergedRules -and $mergedRules.preflight.ContainsKey('require_selftest')) { $mergedRules.preflight.require_selftest } else { $false }
    if ($hasSelfTest) {
        $notes += "Detected -SelfTest flag (component-level testing)"
    } elseif ($requireSelfTest) {
        $reasons += 'component_test verification script must include -SelfTest flag.'
    }

    $forbidDotSourcing = if ($mergedRules -and $mergedRules.preflight.ContainsKey('forbid_dot_sourcing')) { $mergedRules.preflight.forbid_dot_sourcing } else { $false }
    if ($hasSelfTest -or $forbidDotSourcing) {
        $hasDotSourcing = $scriptContent -match '(?i)\.\s+' -or $scriptContent -match '(?i)\bsource\s+'
        if ($hasDotSourcing) {
            $reasons += 'component_test with -SelfTest must use process isolation (& pwsh -File), not dot-sourcing.'
        }
    }

    $staticOnlyPatternCount = 0
    foreach ($pattern in @('(?i)\bTest-Path\b', '(?i)\bGet-Content\b', '(?i)\s-match\s', '(?i)\[System\.Management\.Automation\.Language\.Parser\]::ParseInput', '(?i)\[guid\]::Parse')) {
        if ($scriptContent -match $pattern) {
            $staticOnlyPatternCount++
        }
    }

    $integrationLike = Test-MconVerificationTaskLooksLikeIntegration -Task $Task -ImplementationFiles $implementationFiles
    $workspaceConfigLike = Test-MconVerificationTaskLooksLikeWorkspaceConfig -Task $Task

    $requireRuntimeSignals = if ($mergedRules -and $mergedRules.preflight.ContainsKey('require_runtime_signals')) { $mergedRules.preflight.require_runtime_signals } else { $true }

    if ($integrationLike -and $runtimeSignalCount -eq 0 -and -not $hasSelfTest -and $requireRuntimeSignals) {
        $reasons += 'Integration-like task has no runtime or behavior-exercising checks; verification is static-only.'
    }

    if ($integrationLike -and $staticOnlyPatternCount -gt 0 -and $runtimeSignalCount -eq 0 -and $requireRuntimeSignals) {
        $reasons += 'Verification relies on file presence/content checks only for a multi-file implementation task.'
    }

    # Static-only rejection (skippable via profile)
    $skipStaticOnlyRejection = $mergedRules -and $mergedRules.preflight.skip_static_only_rejection
    if ($workspaceConfigLike -and $runtimeSignalCount -eq 0 -and $staticOnlyPatternCount -gt 0) {
        # Remove static-only rejection for workspace config; content checks are the verification
        $staticOnlyRejection = $reasons | Where-Object { $_ -match 'static-only' -or $_ -match 'file presence/content checks only' }
        if ($staticOnlyRejection) {
            $reasons = @($reasons | Where-Object { $_ -notin $staticOnlyRejection })
        }
    }

    # HYBRID DETECTION: Task looks like documentation but contains executable files
    $looksLikeDocs = Test-MconVerificationTaskLooksLikeDocs -Task $Task
    $hasExecutableFiles = ($implementationFiles.Count -gt 0)
    $taskClass = if ($Task.PSObject.Properties.Name -contains 'task_class') { [string]$Task.task_class } else { '' }
    $isExemptTaskType = $integrationLike -or $taskClass -in @('workspace_config', 'docs_content', 'design_exploratory')

    if ($looksLikeDocs -and $hasExecutableFiles -and -not $isExemptTaskType) {
        $executableNames = @($implementationFiles | Select-Object -ExpandProperty Name)
        $conflictMsg = "Task appears to be documentation but includes executable files: $($executableNames -join ', '). Either remove executables for a pure documentation task, or reclassify the task as hybrid/code and adjust verification accordingly."
        $reasons += $conflictMsg
    }

    if ($runtimeSignalCount -gt 0) {
        $notes += "Detected runtime signals: $runtimeSignalCount"
    }
    if ($mentionedImplementationFiles.Count -gt 0) {
        $notes += "Targets implementation files: $($mentionedImplementationFiles -join ', ')"
    }

    # Profile-driven required patterns
    if ($mergedRules -and $mergedRules.required_patterns) {
        foreach ($pattern in $mergedRules.required_patterns) {
            if (-not ($scriptContent -match [regex]::Escape($pattern))) {
                $reasons += "Verification script must include required pattern: $pattern"
            }
        }
    }

    # Profile-driven forbidden patterns
    if ($mergedRules -and $mergedRules.forbidden_patterns) {
        foreach ($pattern in $mergedRules.forbidden_patterns) {
            if ($scriptContent -match [regex]::Escape($pattern)) {
                $reasons += "Verification script contains forbidden pattern: $pattern"
            }
        }
    }

    # Fallback: workspace_config main path check (preserved for backward compat when no profile loaded)
    if ($workspaceConfigLike -and (-not $mergedRules -or $mergedRules.required_patterns.Count -eq 0)) {
        $mainWorkspacePattern = '/home/cronjev/\.openclaw/workspace/'
        $hasMainWorkspaceRef = $scriptContent -match [regex]::Escape($mainWorkspacePattern)
        if (-not $hasMainWorkspaceRef) {
            $reasons += 'workspace_config verification must check the main workspace file (e.g., /home/cronjev/.openclaw/workspace/AGENTS.md), not a task bundle copy.'
        }
    }

    return [ordered]@{
        passed = ($reasons.Count -eq 0)
        related_deliverable_count = $deliverables.Count
        implementation_deliverable_count = $implementationFiles.Count
        mentioned_deliverables = $mentionedDeliverables
        mentioned_implementation_deliverables = $mentionedImplementationFiles
        integration_like = $integrationLike
        runtime_signal_count = $runtimeSignalCount
        static_only_pattern_count = $staticOnlyPatternCount
        reasons = $reasons
        notes = $notes
        profile_matched = if ($matchedProfile) { $true } else { $false }
        task_rules_applied = if ($taskRules) { $true } else { $false }
    }
}

function Get-MconVerificationPaths {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)]$TaskBundlePaths
    )

    $deliverablesDir = $TaskBundlePaths.deliverables_directory
    $primaryDeliverablePath = Get-MconPrimaryDeliverablePath -DeliverablesDirectory $deliverablesDir -TaskId $TaskId
    $relatedDeliverables = @(Get-MconVerificationCandidateDeliverables -DeliverablesDirectory $deliverablesDir -TaskId $TaskId)

    # Task class overrides keyword-based detection
    $taskClass = if ($Task.PSObject.Properties.Name -contains 'task_class' -and $Task.task_class) { [string]$Task.task_class } else { '' }
    $isDocsTaskClass = $taskClass -in @('docs_content', 'design_exploratory')
    $isSysadminTaskClass = $taskClass -eq 'sysadmin_script_review'

    # Auto-detect sysadmin tasks: if evaluate-*.json exists and script contains sysadmin patterns
    $judgeSpecPath = Join-Path $deliverablesDir "evaluate-$TaskId.json"
    $hasJudgeSpec = Test-Path -LiteralPath $judgeSpecPath
    $isSysadminAutoDetect = $false
    if (-not $isDocsTaskClass -and $hasJudgeSpec -and (Test-Path -LiteralPath $primaryDeliverablePath)) {
        try {
            $scriptContent = Get-Content -LiteralPath $primaryDeliverablePath -Raw -ErrorAction SilentlyContinue
            if ($scriptContent) {
                # Look for sysadmin patterns: sudo, system paths, log management, service management
                $hasSysadminPatterns = $scriptContent -match '(?i)(sudo|/var/log|/etc/|systemctl|service|crontab|ufw|firewall)'
                $isSysadminAutoDetect = $hasSysadminPatterns
            }
        } catch {
            # If we can't read the file, don't auto-detect
        }
    }

    if ($isSysadminTaskClass -or $isSysadminAutoDetect) {
        # Sysadmin task: always use sysadmin verification kind
        $verificationKind = 'sysadmin_review'
        $verificationArtifactPath = Join-Path $deliverablesDir "verify-$TaskId.ps1"

        if (-not (Test-Path -LiteralPath $verificationArtifactPath)) {
            $templatePath = '/home/cronjev/mission-control-tfsmrt/scripts/verify-sysadmin-template.ps1'
            if (-not (Test-Path -LiteralPath $templatePath)) {
                throw "Sysadmin verification wrapper template not found: $templatePath"
            }
            Copy-Item -LiteralPath $templatePath -Destination $verificationArtifactPath -Force
        }

        return [ordered]@{
            verification_kind = $verificationKind
            primary_deliverable_path = $primaryDeliverablePath
            related_deliverable_paths = @($relatedDeliverables | ForEach-Object { $_.FullName })
            verification_artifact_path = $verificationArtifactPath
            judge_spec_path = if (Test-Path -LiteralPath $judgeSpecPath) { $judgeSpecPath } else { $null }
        }
    }

    if ($isDocsTaskClass -or (Test-MconVerificationTaskLooksLikeDocs -Task $Task)) {
        $verificationKind = 'documentation'
        $judgeSpecPath = Join-Path $deliverablesDir "evaluate-$TaskId.json"
        $verificationArtifactPath = Join-Path $deliverablesDir "verify-$TaskId.ps1"

        if (Test-Path -LiteralPath $judgeSpecPath) {
            if (-not (Test-Path -LiteralPath $verificationArtifactPath)) {
                $templatePath = '/home/cronjev/mission-control-tfsmrt/scripts/verify-docs-template.ps1'
                if (-not (Test-Path -LiteralPath $templatePath)) {
                    throw "Docs verification wrapper template not found: $templatePath"
                }
                Copy-Item -LiteralPath $templatePath -Destination $verificationArtifactPath -Force
            }

            return [ordered]@{
                verification_kind = $verificationKind
                primary_deliverable_path = $primaryDeliverablePath
                related_deliverable_paths = @($relatedDeliverables | ForEach-Object { $_.FullName })
                verification_artifact_path = $verificationArtifactPath
                judge_spec_path = $judgeSpecPath
            }
        }
    }

    $verificationArtifactPath = Join-Path $deliverablesDir "verify-$TaskId.ps1"
    if (-not (Test-Path -LiteralPath $verificationArtifactPath)) {
        throw "Verification script not found: $verificationArtifactPath"
    }

    return [ordered]@{
        verification_kind = 'deterministic'
        primary_deliverable_path = $primaryDeliverablePath
        related_deliverable_paths = @($relatedDeliverables | ForEach-Object { $_.FullName })
        verification_artifact_path = $verificationArtifactPath
        judge_spec_path = $null
    }
}

function Invoke-MconVerificationProcess {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)]$VerificationPaths,
        [Parameter(Mandatory)]$TaskBundlePaths,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Task
    )

    $evidenceDir = $TaskBundlePaths.evidence_directory
    if (-not (Test-Path -LiteralPath $evidenceDir)) {
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    }

    # Build verification command
    $verificationScript = $VerificationPaths.verification_artifact_path
    if ($VerificationPaths.verification_kind -eq 'documentation') {
        $command = @(
            'pwsh', '-NoProfile', '-File', ('"' + $verificationScript + '"'),
            '-TaskId', $TaskId,
            '-DocumentPath', $VerificationPaths.primary_deliverable_path,
            '-JudgeSpecPath', $VerificationPaths.judge_spec_path,
            '-EvidenceDir', $evidenceDir
        )
    } elseif ($VerificationPaths.verification_kind -eq 'sysadmin_review') {
        $command = @(
            'pwsh', '-NoProfile', '-File', ('"' + $verificationScript + '"'),
            '-TaskId', $TaskId,
            '-ScriptPath', $VerificationPaths.primary_deliverable_path,
            '-JudgeSpecPath', $VerificationPaths.judge_spec_path,
            '-EvidenceDir', $evidenceDir
        )
    } else {
        $command = @('pwsh', '-NoProfile', '-File', $verificationScript)
    }

    # Run directly; capture stdout, stderr, and exit code
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $command[0]
    $psi.Arguments = ($command | Select-Object -Skip 1) -join ' '
    $psi.WorkingDirectory = $Config.workspace_path
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) {
        throw "Failed to start verification process: $verificationScript"
    }

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(300000) | Out-Null
    $exitCode = $proc.ExitCode

    $stdoutText = ($stdout + "`n" + $stderr).Trim()

    $validationResultPath = Join-Path $evidenceDir "validation-result-$TaskId.json"
    $parsedResult = $null
    if (Test-Path -LiteralPath $validationResultPath) {
        try {
            $parsedResult = Get-Content -LiteralPath $validationResultPath -Raw | ConvertFrom-Json -Depth 100
        } catch {
            $parsedResult = $null
        }
    }

    $passed = $false
    if (($VerificationPaths.verification_kind -eq 'documentation' -or $VerificationPaths.verification_kind -eq 'sysadmin_review') -and $parsedResult -and ($parsedResult.PSObject.Properties.Name -contains 'passed')) {
        $passed = [bool]$parsedResult.passed
    } else {
        $passed = ($exitCode -eq 0)
    }

    return [ordered]@{
        exit_code = $exitCode
        stdout = $stdoutText
        validation_result_path = if (Test-Path -LiteralPath $validationResultPath) { $validationResultPath } else { $null }
        passed = $passed
    }
}

function Get-MconVerificationTaskClass {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$VerificationPaths
    )

    if ($Task.PSObject.Properties.Name -contains 'task_class' -and $Task.task_class) {
        return [string]$Task.task_class
    }

    if ($VerificationPaths.verification_kind -eq 'documentation') {
        return 'docs_content'
    }

    if ($VerificationPaths.verification_kind -eq 'sysadmin_review') {
        return 'sysadmin_script_review'
    }

    return 'code_deterministic'
}

function Get-MconVerificationEvidenceArtifact {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$RelativePath,
        [bool]$IsPrimary = $false
    )

    return [ordered]@{
        kind = $Kind
        label = $Label
        relative_path = $RelativePath
        display_path = $RelativePath
        origin_kind = 'workspace_file'
        is_primary = $IsPrimary
    }
}

function New-MconVerificationEvidencePacketBody {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$VerificationPaths,
        [Parameter(Mandatory)]$ExecutionResult,
        [Parameter(Mandatory)]$TaskBundlePaths
    )

    $primaryDeliverableName = Split-Path $VerificationPaths.primary_deliverable_path -Leaf
    $verificationArtifactName = Split-Path $VerificationPaths.verification_artifact_path -Leaf
    $artifacts = @(
        (Get-MconVerificationEvidenceArtifact `
            -Kind 'deliverable' `
            -Label $primaryDeliverableName `
            -RelativePath "deliverables/$primaryDeliverableName" `
            -IsPrimary $true),
        (Get-MconVerificationEvidenceArtifact `
            -Kind 'verification_script' `
            -Label $verificationArtifactName `
            -RelativePath "deliverables/$verificationArtifactName")
    )

    if ($ExecutionResult.validation_result_path) {
        $validationResultName = Split-Path $ExecutionResult.validation_result_path -Leaf
        $artifacts += Get-MconVerificationEvidenceArtifact `
            -Kind 'validation_result' `
            -Label $validationResultName `
            -RelativePath "evidence/$validationResultName"
    }

    $stdoutSummary = if ([string]::IsNullOrWhiteSpace($ExecutionResult.stdout)) {
        'Verification completed with no stdout/stderr output.'
    } else {
        [string]$ExecutionResult.stdout
    }

    $checkStatus = if ($ExecutionResult.passed) { 'passed' } else { 'failed' }
    $checkCommand = "pwsh -NoProfile -File deliverables/$verificationArtifactName"

    return [ordered]@{
        task_class = Get-MconVerificationTaskClass -Task $Task -VerificationPaths $VerificationPaths
        status = 'submitted'
        summary = "Verifier executed $($VerificationPaths.verification_kind) checks and observed $checkStatus."
        implementation_delta = "Verified deliverable deliverables/$primaryDeliverableName using deliverables/$verificationArtifactName."
        review_notes = $stdoutSummary
        artifacts = $artifacts
        checks = @(
            [ordered]@{
                kind = 'verification'
                label = "Verifier check for $verificationArtifactName"
                status = $checkStatus
                command = $checkCommand
                result_summary = $stdoutSummary
            }
        )
    }
}

function Submit-MconVerificationEvidencePacket {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$VerificationPaths,
        [Parameter(Mandatory)]$ExecutionResult,
        [Parameter(Mandatory)]$TaskBundlePaths
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $uri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask/evidence-packets"
    $body = New-MconVerificationEvidencePacketBody `
        -Task $Task `
        -VerificationPaths $VerificationPaths `
        -ExecutionResult $ExecutionResult `
        -TaskBundlePaths $TaskBundlePaths
    return Invoke-MconApi -Method Post -Uri $uri -Token $Token -Body $body
}

function New-MconVerificationComment {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)]$VerificationPaths,
        [Parameter(Mandatory)]$ExecutionResult,
        [Parameter(Mandatory)][string]$ResultingTaskStatus,
        $EvidencePacket,
        $Preflight = $null
    )

    $decision = if ($ExecutionResult.passed) { 'PASS' } else { 'FAIL' }
    $actionTaken = if ($ExecutionResult.passed) { 'moved to done' } else { 'rework dispatched to worker' }
    $resultPath = if ($ExecutionResult.validation_result_path) { $ExecutionResult.validation_result_path } else { 'none' }
    $stdoutSummary = if ([string]::IsNullOrWhiteSpace($ExecutionResult.stdout)) { 'none' } else { $ExecutionResult.stdout }
    $preflightSummary = if ($null -ne $Preflight) {
        if ($Preflight.passed) {
            'passed'
        } else {
            [string](@($Preflight.reasons) -join ' | ')
        }
    } else {
        'not_run'
    }
    $evidencePacketId = if (
        $null -ne $EvidencePacket -and
        $EvidencePacket.PSObject.Properties.Name -contains 'id'
    ) {
        [string]$EvidencePacket.id
    } else {
        'none'
    }

    return @"
Verifier execution: $decision
Task ID: $TaskId
Verification kind: $($VerificationPaths.verification_kind)
Verification artifact: $($VerificationPaths.verification_artifact_path)
Validation result: $resultPath
Evidence packet: $evidencePacketId
Exit code: $($ExecutionResult.exit_code)
Preflight: $preflightSummary
Action: $actionTaken
Resulting task status: $ResultingTaskStatus
Output: $stdoutSummary
"@
}

function Test-MconVerificationStuckTask {
    <#
    .SYNOPSIS
        Detects whether a task is stuck in a verification failure loop.
    .DESCRIPTION
        Analyzes recent task comments to count consecutive verification
        preflight failures. Returns diagnostic info if the task appears stuck.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId,
        [int]$StuckThreshold = 3
    )

    $comments = Get-MconTaskComments -BaseUrl $BaseUrl -Token $Token -BoardId $BoardId -TaskId $TaskId
    if (-not $comments) {
        return [ordered]@{
            is_stuck = $false
            failure_count = 0
            latest_reason = $null
            suggestion = $null
        }
    }

    # Look for recent verifier comments indicating preflight failure
    $preflightFailures = @()
    $latestPreflightReason = $null
    foreach ($comment in ($comments | Sort-Object created_at -Descending)) {
        $msg = if ($comment.message) { [string]$comment.message } else { '' }
        if ($msg -match 'Verification preflight failed:') {
            $reason = if ($msg -match 'Verification preflight failed:\s*(.+?)(?:\r?\n|$)') { $matches[1].Trim() } else { 'unknown' }
            $preflightFailures += [ordered]@{
                reason = $reason
                created_at = $comment.created_at
            }
            if (-not $latestPreflightReason) {
                $latestPreflightReason = $reason
            }
        }
    }

    $isStuck = $preflightFailures.Count -ge $StuckThreshold
    $suggestion = $null
    if ($isStuck) {
        $suggestion = @"
TASK STUCK IN VERIFICATION

This task has failed verification preflight $($preflightFailures.Count) times with the same or similar reasons.
Latest failure: $latestPreflightReason

To unblock this task, a lead or gateway agent can apply custom verification rules:

  mcon verify set-rules --task $TaskId --rules '{"preflight":{"skip_static_only_rejection":true},"required_patterns":["..."]}'
"@
    }

    return [ordered]@{
        is_stuck = $isStuck
        failure_count = $preflightFailures.Count
        latest_reason = $latestPreflightReason
        suggestion = $suggestion
    }
}

function Set-MconVerificationRules {
    <#
    .SYNOPSIS
        Patches the verification_rules field on a task.
    .DESCRIPTION
        Used by lead or gateway agents to dynamically extend verification
        logic for a stuck task without editing PowerShell code.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$BoardId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][hashtable]$Rules
    )

    $encodedBoard = [uri]::EscapeDataString($BoardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $taskUri = "$BaseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask"

    $body = @{
        verification_rules = $Rules
    }

    return Invoke-MconApi -Method Patch -Uri $taskUri -Token $Token -Body $body
}

function Invoke-MconVerifyRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TaskId,
        [string]$MconScriptPath
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id
    $workspacePath = $Config.workspace_path

    $leadWorkspacePath = "/home/cronjev/.openclaw/workspace-lead-$boardId"
    $leadConfig = Resolve-MconLeadAgentConfig -BoardId $boardId
    if (-not $leadConfig) {
        throw "Board lead credentials are required for verifier outcome routing but were not found in the local keybag."
    }

    $task = Get-MconTask -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId
    if ($task.status -ne 'review') {
        throw "Task must be in review before verifier execution. Current status: $($task.status)"
    }

    $taskBundlePaths = Get-MconVerifyTaskBundlePaths -LeadWorkspacePath $leadWorkspacePath -TaskId $TaskId

    $verificationPaths = $null
    $preflight = $null
    $executionResult = $null

    try {
        if (-not (Test-Path -LiteralPath $taskBundlePaths.deliverables_directory)) {
            throw "Deliverables directory not found: $($taskBundlePaths.deliverables_directory)"
        }

        $verificationPaths = Get-MconVerificationPaths -Task $task -TaskId $TaskId -TaskBundlePaths $taskBundlePaths
        $preflight = Test-MconVerificationPreflight -Task $task -VerificationPaths $verificationPaths -TaskBundlePaths $taskBundlePaths
        if (-not $preflight.passed) {
            $executionResult = [ordered]@{
                exit_code = 1
                stdout = "Verification preflight failed: $(@($preflight.reasons) -join '; ')"
                validation_result_path = $null
                passed = $false
            }
        } else {
            $executionResult = Invoke-MconVerificationProcess -TaskId $TaskId -VerificationPaths $verificationPaths -TaskBundlePaths $taskBundlePaths -Config $Config -Task $task
        }
    } catch {
        $verificationPaths = [ordered]@{
            verification_kind = 'unavailable'
            primary_deliverable_path = $null
            related_deliverable_paths = @()
            verification_artifact_path = 'unavailable'
            judge_spec_path = $null
        }
        $preflight = $null
        $executionResult = [ordered]@{
            exit_code = 1
            stdout = "Verification preparation failed: $($_.Exception.Message)"
            validation_result_path = $null
            passed = $false
        }
    }

    $resultingTaskStatus = if ($executionResult.passed) { 'done' } else { 'in_progress' }
    $actionTaken = if ($executionResult.passed) { 'mark_done' } else { 'rework' }
    $evidencePacket = $null
    if ($executionResult.passed) {
        $evidencePacket = Submit-MconVerificationEvidencePacket `
            -BaseUrl $baseUrl `
            -Token $authToken `
            -BoardId $boardId `
            -TaskId $TaskId `
            -Task $task `
            -VerificationPaths $verificationPaths `
            -ExecutionResult $executionResult `
            -TaskBundlePaths $taskBundlePaths
    }
    $commentMessage = New-MconVerificationComment `
        -TaskId $TaskId `
        -VerificationPaths $verificationPaths `
        -ExecutionResult $executionResult `
        -ResultingTaskStatus $resultingTaskStatus `
        -EvidencePacket $evidencePacket `
        -Preflight $preflight

    $comment = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $commentMessage

    # Stuck-task detection: if preflight keeps failing with the same reason, alert the lead
    $stuckCheck = $null
    if (-not $executionResult.passed -and $preflight -and -not $preflight.passed) {
        $stuckCheck = Test-MconVerificationStuckTask -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -StuckThreshold 3
        if ($stuckCheck.is_stuck) {
            $null = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $stuckCheck.suggestion
        }
    }

    $originalAssignedAgentId = if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
        [string]$task.assigned_agent_id
    } else { $null }

    $encodedBoard = [uri]::EscapeDataString($boardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $statusPatchBody = @{ status = $resultingTaskStatus }
    if (-not $executionResult.passed -and $originalAssignedAgentId) {
        $statusPatchBody.assigned_agent_id = $originalAssignedAgentId
    }

    # Use LOCAL_AUTH_TOKEN and user endpoint for status transitions
    $userTaskUri = "$baseUrl/api/v1/boards/$encodedBoard/tasks/$encodedTask"
    $updatedTask = Invoke-MconLocalAuthApi -Method Patch -Uri $userTaskUri -Body $statusPatchBody

    $reworkDispatch = $null
    $escalationResult = $null
    if (-not $executionResult.passed) {
        $assignedAgentId = if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
            [string]$task.assigned_agent_id
        } else { $null }

        if ([string]::IsNullOrWhiteSpace($assignedAgentId)) {
            $reworkDispatch = [ordered]@{
                ok     = $false
                reason = 'no_assigned_agent_id'
                note   = "Task assigned_agent_id is null or empty. Cannot determine which worker to dispatch rework to."
            }
        } else {
            $openClawId = "mc-$assignedAgentId"
            $openClawRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $openClawRoot = if ($leadConfig.workspace_path) { Split-Path -Parent $leadConfig.workspace_path } else { $openClawRoot }

            $workerWorkspacePath = Join-Path $openClawRoot "workspace-$openClawId"
            $workspaceExists = Test-Path -LiteralPath $workerWorkspacePath

            if ($workspaceExists) {
                $childSessionKey = "agent:$openClawId`:task:$TaskId"

                try {
                    $workerConfig = Resolve-MconOpenClawAgentConfig -WorkspacePath $workerWorkspacePath
                    $workerName = $workerConfig.name

                    $commentsUri = "$baseUrl/api/v1/agent/boards/$([uri]::EscapeDataString($boardId))/tasks/$([uri]::EscapeDataString($TaskId))/comments?limit=50"
                    $reworkCommentsResponse = $null
                    try {
                        $reworkCommentsResponse = Invoke-MconApi -Method Get -Uri $commentsUri -Token $authToken
                    } catch {}

                    $normalizedComments = @()
                    if ($reworkCommentsResponse) {
                        if ($reworkCommentsResponse.PSObject.Properties.Name -contains 'items') {
                            $normalizedComments = @($reworkCommentsResponse.items | Where-Object { $null -ne $_ })
                        } elseif ($reworkCommentsResponse.PSObject.Properties.Name -contains 'comments') {
                            $normalizedComments = @($reworkCommentsResponse.comments | Where-Object { $null -ne $_ })
                        }
                    }

                    $bundle = New-MconBootstrapBundle -BoardId $boardId -TaskId $TaskId -WorkerAgentId $assignedAgentId -WorkerName $workerName -LeadWorkspacePath $leadConfig.workspace_path -WorkerWorkspacePath $workerWorkspacePath -TaskData $task -Comments $normalizedComments
                    $bundlePath = Join-Path (Join-Path $leadConfig.workspace_path 'deliverables') "$TaskId-rework-bootstrap.json"
                    $bundle | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bundlePath -Encoding UTF8

                    $workerTaskDataPath = Write-MconWorkerTaskData -WorkerWorkspacePath $workerWorkspacePath -BoardId $boardId -LeadAgentId $leadConfig.agent_id -InvocationAgentId $leadConfig.agent_id -TaskData $task -Comments $normalizedComments -TaskBundlePaths $taskBundlePaths

                    $reworkPrompt = @"
# VERIFICATION FAILED — REWORK REQUIRED

Task $TaskId verification failed and requires rework.

## Verification Feedback
$commentMessage

## Updated Context Files
- Bootstrap bundle: $bundlePath
- Task data: $workerTaskDataPath

## Work Contract
- Read the existing deliverables and fix only what needs fixing
- After completing rework, post a handoff comment and move the task to review
- If blocked, comment with the exact blocker and stop
"@

                    $dispatchResponse = Send-MconOpenClawSessionMessage `
                        -WorkspacePath ([string]$leadConfig.workspace_path) `
                        -InvocationAgent $openClawId `
                        -SessionKey $childSessionKey `
                        -Message $reworkPrompt `
                        -TaskId $TaskId `
                        -DispatchType 'rework' `
                        -TimeoutSec 300 `
                        -Temperature 0

                    $reworkDispatch = [ordered]@{
                        ok          = $true
                        session_key = $childSessionKey
                        agent_id    = $openClawId
                        response    = $dispatchResponse
                    }
                } catch {
                    $reworkDispatch = [ordered]@{
                        ok     = $false
                        reason = 'rework_dispatch_exception'
                        error  = $_.Exception.Message
                    }
                }

            } else {
                $reworkDispatch = [ordered]@{
                    ok     = $false
                    reason = 'no_worker_workspace'
                    note   = "Worker workspace not found at $workerWorkspacePath for agent $assignedAgentId."
                }
            }
        }

        # Fallback: if rework could not be dispatched, move to inbox so lead can reassign
        if (-not $reworkDispatch -or -not $reworkDispatch.ok) {
            try {
                $fallbackComment = "Verification failed and rework could not be dispatched to worker. Reason: $($reworkDispatch.reason). $($reworkDispatch.note). Task remains in_progress for lead reassignment."
                $null = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $fallbackComment
                # Only move to inbox if still in review; if already in_progress, leave it there
                $currentTask = Get-MconTask -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId
                if ($currentTask.status -eq 'review') {
                    $null = Set-MconTaskStatus -BaseUrl $leadConfig.base_url -Token $leadConfig.auth_token -BoardId $boardId -TaskId $TaskId -Status 'inbox'
                    $escalationResult = [ordered]@{
                        ok     = $true
                        action = 'returned_to_inbox'
                        reason = $reworkDispatch.reason
                    }
                } else {
                    $escalationResult = [ordered]@{
                        ok     = $true
                        action = 'left_in_progress'
                        reason = $reworkDispatch.reason
                        note   = "Task status is $($currentTask.status); skipped inbox fallback."
                    }
                }
            } catch {
                $escalationResult = [ordered]@{
                    ok    = $false
                    action = 'fallback_failed'
                    error = $_.Exception.Message
                }
            }
        }
    }

    $closureDispatch = $null
    $reflectionDispatches = @()
    if ($executionResult.passed -and $updatedTask.status -eq 'done') {
        # 1. Send reflection prompts directly to worker and verifier
        $workerAgentId = if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
            [string]$task.assigned_agent_id
        } else { $null }

        if ($workerAgentId) {
            $workerOpenClawId = "mc-$workerAgentId"
            $workerReflection = Send-MconTaskReflectionPrompt `
                -WorkspacePath ([string]$leadConfig.workspace_path) `
                -InvocationAgent $workerOpenClawId `
                -TaskId $TaskId `
                -TaskTitle ([string]$task.title) `
                -TimeoutSec 15
            $reflectionDispatches += [ordered]@{
                role = 'worker'
                agent_id = $workerOpenClawId
                result = $workerReflection
            }
        }

        # Try to identify verifier from comments (best-effort)
        $verifierAgentId = $null
        try {
            $commentsUri = "$baseUrl/api/v1/agent/boards/$encodedBoard/tasks/$encodedTask/comments?limit=50"
            $commentsResponse = Invoke-MconApi -Method Get -Uri $commentsUri -Token $authToken
            $commentItems = @()
            if ($commentsResponse.PSObject.Properties.Name -contains 'items') {
                $commentItems = @($commentsResponse.items | Where-Object { $null -ne $_ })
            }
            # Look for comments from agents that are not the worker and not the lead
            foreach ($c in $commentItems) {
                $commentAgentId = if ($c.PSObject.Properties.Name -contains 'agent_id' -and $c.agent_id) { [string]$c.agent_id } else { $null }
                if ($commentAgentId -and $commentAgentId -ne $workerAgentId -and $commentAgentId -ne $leadConfig.agent_id) {
                    $verifierAgentId = $commentAgentId
                    break
                }
            }
        } catch {}

        if ($verifierAgentId) {
            $verifierOpenClawId = "mc-$verifierAgentId"
            $verifierReflection = Send-MconTaskReflectionPrompt `
                -WorkspacePath ([string]$leadConfig.workspace_path) `
                -InvocationAgent $verifierOpenClawId `
                -TaskId $TaskId `
                -TaskTitle ([string]$task.title) `
                -TimeoutSec 15
            $reflectionDispatches += [ordered]@{
                role = 'verifier'
                agent_id = $verifierOpenClawId
                result = $verifierReflection
            }
        }

        # 2. Send closure directive to lead for follow-up work (dependency checks, follow-up tasks, etc.)
        $taskDataPath = Join-Path $taskBundlePaths.task_directory 'taskData.json'
        $closureDirective = New-MconLeadClosureDirective -TaskRefs @(
            [pscustomobject]@{
                id              = $TaskId
                title           = [string]$task.title
                status          = 'done'
                taskDataPath    = $taskDataPath
                deliverablesDir = $taskBundlePaths.deliverables_directory
                evidenceDir     = $taskBundlePaths.evidence_directory
            }
        )

        if (-not [string]::IsNullOrWhiteSpace($closureDirective)) {
            $leadInvocationAgent = "lead-$boardId"
            $leadSessionKey = Get-MconAgentTaskSessionKey -InvocationAgent $leadInvocationAgent -TaskId $TaskId
            try {
                $diagnosticsDir = Join-Path $taskBundlePaths.evidence_directory 'session-dispatch'
                $deferredPayload = [ordered]@{
                    workspace_path        = [string]$leadConfig.workspace_path
                    invocation_agent      = $leadInvocationAgent
                    session_key           = $leadSessionKey
                    message               = $closureDirective
                    task_id               = $TaskId
                    dispatch_type         = 'verify_closure'
                    timeout_seconds       = 120
                    temperature           = 0
                    initial_delay_seconds = 0
                }
                $response = Start-MconDeferredSessionDispatch `
                    -WorkspacePath ([string]$leadConfig.workspace_path) `
                    -MconScriptPath $MconScriptPath `
                    -DiagnosticsDir $diagnosticsDir `
                    -TaskId $TaskId `
                    -Payload $deferredPayload
                $closureDispatch = [ordered]@{
                    ok          = $true
                    session_key = $leadSessionKey
                    agent_id    = $leadInvocationAgent
                    queued      = $true
                    dispatch    = $response
                }
            } catch {
                $closureDispatch = [ordered]@{
                    ok          = $false
                    session_key = $leadSessionKey
                    agent_id    = $leadInvocationAgent
                    queued      = $false
                    error       = $_.Exception.Message
                }
            }
        }
    }

    return [ordered]@{
        ok = $true
        task_id = $TaskId
        verification_kind = $verificationPaths.verification_kind
        verification_artifact_path = $verificationPaths.verification_artifact_path
        validation_result_path = $executionResult.validation_result_path
        evidence_packet_id = if ($null -ne $evidencePacket -and $evidencePacket.PSObject.Properties.Name -contains 'id') { $evidencePacket.id } else { $null }
        passed = $executionResult.passed
        resulting_task_status = $updatedTask.status
        action_taken = $actionTaken
        closure_dispatch = $closureDispatch
        reflection_dispatches = $reflectionDispatches
        rework_dispatch = $reworkDispatch
        escalation_result = $escalationResult
        comment_id = if ($comment.PSObject.Properties.Name -contains 'id') { $comment.id } else { $null }
        task = $updatedTask
    }
}

function Invoke-MconVerifyFail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Message
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id

    $leadConfig = Resolve-MconLeadAgentConfig -BoardId $boardId
    if (-not $leadConfig) {
        throw "Board lead credentials are required for verifier outcome routing but were not found in the local keybag."
    }

    $task = Get-MconTask -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId
    if ($task.status -ne 'review') {
        throw "Task must be in review before verifier can fail it. Current status: $($task.status)"
    }

    $comment = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $Message

    $assignedAgentId = if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
        [string]$task.assigned_agent_id
    } else { $null }

    $encodedBoard = [uri]::EscapeDataString($boardId)
    $encodedTask = [uri]::EscapeDataString($TaskId)
    $statusPatchBody = @{ status = 'in_progress' }
    if ($assignedAgentId) {
        $statusPatchBody.assigned_agent_id = $assignedAgentId
    }

    # Use LOCAL_AUTH_TOKEN (user endpoint) for status transitions
    $userTaskUri = "$baseUrl/api/v1/boards/$encodedBoard/tasks/$encodedTask"
    $updatedTask = Invoke-MconLocalAuthApi -Method Patch -Uri $userTaskUri -Body $statusPatchBody

    $reworkDispatch = $null
    $escalationResult = $null

    if ([string]::IsNullOrWhiteSpace($assignedAgentId)) {
        $reworkDispatch = [ordered]@{
            ok     = $false
            reason = 'no_assigned_agent_id'
            note   = "Task assigned_agent_id is null or empty. Cannot determine which worker to dispatch rework to."
        }
    } else {
        $openClawId = "mc-$assignedAgentId"
        $openClawRoot = Split-Path -Parent $leadConfig.workspace_path
        $workerWorkspacePath = Join-Path $openClawRoot "workspace-$openClawId"
        $workspaceExists = Test-Path -LiteralPath $workerWorkspacePath

        if ($workspaceExists) {
            $childSessionKey = "agent:$openClawId`:task:$TaskId"
            $taskBundlePaths = Get-MconAssignTaskBundlePaths -LeadWorkspacePath $leadConfig.workspace_path -TaskId $TaskId

            try {
                $workerConfig = Resolve-MconOpenClawAgentConfig -WorkspacePath $workerWorkspacePath
                $workerName = $workerConfig.name

                $commentsUri = "$taskUri/comments?limit=50"
                $reworkCommentsResponse = $null
                try {
                    $reworkCommentsResponse = Invoke-MconApi -Method Get -Uri $commentsUri -Token $authToken
                } catch {}

                $normalizedComments = @()
                if ($reworkCommentsResponse) {
                    if ($reworkCommentsResponse.PSObject.Properties.Name -contains 'items') {
                        $normalizedComments = @($reworkCommentsResponse.items | Where-Object { $null -ne $_ })
                    } elseif ($reworkCommentsResponse.PSObject.Properties.Name -contains 'comments') {
                        $normalizedComments = @($reworkCommentsResponse.comments | Where-Object { $null -ne $_ })
                    }
                }

                $bundle = New-MconBootstrapBundle -BoardId $boardId -TaskId $TaskId -WorkerAgentId $assignedAgentId -WorkerName $workerName -LeadWorkspacePath $leadConfig.workspace_path -WorkerWorkspacePath $workerWorkspacePath -TaskData $task -Comments $normalizedComments
                $bundlePath = Join-Path (Join-Path $leadConfig.workspace_path 'deliverables') "$TaskId-rework-bootstrap.json"
                $bundle | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bundlePath -Encoding UTF8

                $workerTaskDataPath = Write-MconWorkerTaskData -WorkerWorkspacePath $workerWorkspacePath -BoardId $boardId -LeadAgentId $leadConfig.agent_id -InvocationAgentId $leadConfig.agent_id -TaskData $task -Comments $normalizedComments -TaskBundlePaths $taskBundlePaths

                $reworkPrompt = @"
# VERIFICATION FAILED — REWORK REQUIRED

Task $TaskId verification failed and requires rework.

## Verification Feedback
$Message

## Updated Context Files
- Bootstrap bundle: $bundlePath
- Task data: $workerTaskDataPath

## Work Contract
- Read the existing deliverables and fix only what needs fixing
- After completing rework, post a handoff comment and move the task to review
- If blocked, comment with the exact blocker and stop
"@

                $dispatchResponse = Send-MconOpenClawSessionMessage `
                    -WorkspacePath ([string]$leadConfig.workspace_path) `
                    -InvocationAgent $openClawId `
                    -SessionKey $childSessionKey `
                    -Message $reworkPrompt `
                    -TaskId $TaskId `
                    -DispatchType 'rework' `
                    -TimeoutSec 300 `
                    -Temperature 0

                $reworkDispatch = [ordered]@{
                    ok          = $true
                    session_key = $childSessionKey
                    agent_id    = $openClawId
                    response    = $dispatchResponse
                }
            } catch {
                $reworkDispatch = [ordered]@{
                    ok     = $false
                    reason = 'rework_dispatch_exception'
                    error  = $_.Exception.Message
                }
            }

        } else {
            $reworkDispatch = [ordered]@{
                ok     = $false
                reason = 'no_worker_workspace'
                note   = "Worker workspace not found at $workerWorkspacePath for agent $assignedAgentId."
            }
        }
    }

    if (-not $reworkDispatch -or -not $reworkDispatch.ok) {
        try {
            $fallbackComment = "Verification failed and rework could not be dispatched to worker. Reason: $($reworkDispatch.reason). $($reworkDispatch.note). Task remains in_progress for lead reassignment."
            $null = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $fallbackComment
            # Only move to inbox if still in review; if already in_progress, leave it there
            $currentTask = Get-MconTask -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId
            if ($currentTask.status -eq 'review') {
                $null = Set-MconTaskStatus -BaseUrl $leadConfig.base_url -Token $leadConfig.auth_token -BoardId $boardId -TaskId $TaskId -Status 'inbox'
                $escalationResult = [ordered]@{
                    ok     = $true
                    action = 'returned_to_inbox'
                    reason = $reworkDispatch.reason
                }
            } else {
                $escalationResult = [ordered]@{
                    ok     = $true
                    action = 'left_in_progress'
                    reason = $reworkDispatch.reason
                    note   = "Task status is $($currentTask.status); skipped inbox fallback."
                }
            }
        } catch {
            $escalationResult = [ordered]@{
                ok    = $false
                action = 'fallback_failed'
                error = $_.Exception.Message
            }
        }
    }

    return [ordered]@{
        ok = $true
        task_id = $TaskId
        resulting_task_status = $updatedTask.status
        rework_dispatch = $reworkDispatch
        escalation_result = $escalationResult
        comment_id = if ($comment.PSObject.Properties.Name -contains 'id') { $comment.id } else { $null }
        task = $updatedTask
    }
}

Export-ModuleMember -Function Invoke-MconVerifyRun, Invoke-MconVerifyFail, Test-MconVerificationPreflight, Get-MconVerificationProfilesConfig, Get-MconVerificationProfileForTask, Merge-MconVerificationProfile, Test-MconVerificationStuckTask, Set-MconVerificationRules
