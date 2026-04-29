function Test-MconVerificationTaskLooksLikeDocs {
    param(
        [Parameter(Mandatory)]$Task
    )

    $title = if ($Task.PSObject.Properties.Name -contains 'title') { [string]$Task.title } else { '' }
    $description = if ($Task.PSObject.Properties.Name -contains 'description') { [string]$Task.description } else { '' }
    $text = "$title`n$description"
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

function Test-MconVerificationPreflight {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$VerificationPaths,
        [Parameter(Mandatory)]$TaskBundlePaths
    )

    $verificationArtifactPath = $VerificationPaths.verification_artifact_path
    $deliverables = @(Get-MconVerificationCandidateDeliverables -DeliverablesDirectory $TaskBundlePaths.deliverables_directory -TaskId $Task.id)
    $implementationFiles = @($deliverables | Where-Object { Test-MconDeliverableLooksLikeImplementation -File $_ })
    $scriptContent = Get-Content -LiteralPath $verificationArtifactPath -Raw
    $reasons = @()
    $notes = @()

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

    if ($mentionedDeliverables.Count -eq 0) {
        $reasons += 'Verification script does not reference any non-verification deliverable by filename.'
    }

    if ($implementationFiles.Count -gt 0 -and $mentionedImplementationFiles.Count -eq 0) {
        $implNames = @($implementationFiles | Select-Object -ExpandProperty Name)
        $reasons += "Verification script does not target implementation deliverables directly: $($implNames -join ', ')"
    }

    $hasSuccessExit = $scriptContent -match '(?mi)^\s*exit\s+0\s*$' -or $scriptContent -match '(?mi)^\s*return\s+0\s*$'
    $hasFailureExit = $scriptContent -match '(?mi)^\s*exit\s+1\s*$' -or
        $scriptContent -match '(?mi)^\s*exit\s+\$[A-Za-z_][A-Za-z0-9_]*\s*$' -or
        $scriptContent -match '(?mi)^\s*return\s+1\s*$'
    if ($hasSuccessExit -and -not $hasFailureExit) {
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
        '(?i)&\s*\$[A-Za-z_][A-Za-z0-9_]*',
        '(?i)&\s*["''][^"'']+\.(ps1|py|sh|bash|js|ts)'
    )
    $runtimeSignalCount = 0
    foreach ($pattern in $runtimeSignals) {
        if ($scriptContent -match $pattern) {
            $runtimeSignalCount++
        }
    }

    $staticOnlyPatternCount = 0
    foreach ($pattern in @('(?i)\bTest-Path\b', '(?i)\bGet-Content\b', '(?i)\s-match\s', '(?i)\[System\.Management\.Automation\.Language\.Parser\]::ParseInput', '(?i)\[guid\]::Parse')) {
        if ($scriptContent -match $pattern) {
            $staticOnlyPatternCount++
        }
    }

    $integrationLike = Test-MconVerificationTaskLooksLikeIntegration -Task $Task -ImplementationFiles $implementationFiles
    if ($integrationLike -and $runtimeSignalCount -eq 0) {
        $reasons += 'Integration-like task has no runtime or behavior-exercising checks; verification is static-only.'
    }

    if ($integrationLike -and $staticOnlyPatternCount -gt 0 -and $runtimeSignalCount -eq 0) {
        $reasons += 'Verification relies on file presence/content checks only for a multi-file implementation task.'
    }

    # HYBRID DETECTION: Task looks like documentation but contains executable files
    $looksLikeDocs = Test-MconVerificationTaskLooksLikeDocs -Task $Task
    $hasExecutableFiles = ($implementationFiles.Count -gt 0)

    if ($looksLikeDocs -and $hasExecutableFiles) {
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

    if (Test-MconVerificationTaskLooksLikeDocs -Task $Task) {
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

    # Prepare isolated agent session for verification
    $invocationAgent = "mc-$($Config.agent_id)"
    $sessionKey = Get-MconAgentTaskSessionKey -InvocationAgent $invocationAgent -TaskId $TaskId

    # Compute lead workspace path
    $leadWorkspacePath = Get-MconLeadWorkspacePath -BoardId $Config.board_id

    # Create verifier's task context directory and taskData.json
    $verifierTaskDir = Join-Path (Join-Path $Config.workspace_path 'tasks') $TaskId
    if (-not (Test-Path -LiteralPath $verifierTaskDir)) {
        New-Item -ItemType Directory -Path $verifierTaskDir -Force | Out-Null
    }

    # Fetch comments for the task
    $comments = Get-MconTaskComments -BaseUrl $Config.base_url -Token $Config.auth_token -BoardId $Config.board_id -TaskId $TaskId

    $taskData = [ordered]@{
        generated_at          = (Get-Date).ToUniversalTime().ToString('o')
        board_id              = $Config.board_id
        lead_agent_id         = $Config.board_id
        invocation_agent_id   = $invocationAgent
        task_directory        = $verifierTaskDir
        deliverables_directory = $TaskBundlePaths.deliverables_directory
        evidence_directory    = $TaskBundlePaths.evidence_directory
        task                  = $Task
        comments              = $comments
        boardWorkers          = @()
    }

    $taskDataPath = Join-Path $verifierTaskDir 'taskData.json'
    $taskData | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $taskDataPath -Encoding UTF8

    # Build minimal dispatch state for the prompt
    $dispatchState = [ordered]@{
        tasks = @([ordered]@{
            id            = $TaskId
            status        = 'review'
            title         = $Task.title
            task_data_path = $taskDataPath
            task_directory = $verifierTaskDir
            deliverables_directory = $TaskBundlePaths.deliverables_directory
            evidence_directory = $TaskBundlePaths.evidence_directory
        })
    }

    # Generate the standard verifier prompt
    $prompt = New-MconVerifierPrompt -WorkspacePath $Config.workspace_path -DispatchState $dispatchState -AuthToken $Config.auth_token -SessionKey $sessionKey

    # Build verification command
    $verificationScript = $VerificationPaths.verification_artifact_path
    if ($VerificationPaths.verification_kind -eq 'documentation') {
        $command = @(
            'pwsh -NoProfile -File', $verificationScript,
            '-TaskId', $TaskId,
            '-DocumentPath', $VerificationPaths.primary_deliverable_path,
            '-JudgeSpecPath', $VerificationPaths.judge_spec_path,
            '-EvidenceDir', $evidenceDir
        ) -join ' '
    } else {
        $command = "pwsh -NoProfile -File `"$verificationScript`""
    }

    $prompt += "`n`n# VERIFICATION EXECUTION`n"
    $prompt += "Run the following command exactly and capture its output:`n"
    $prompt += "`$ $command`n"
    $prompt += "After the command completes, exit with the same exit code as the command (0 for pass, non-zero for fail). Include the command's stdout/stderr in your response.`n"

    # Run the agent in an isolated session with verifier's workspace as cwd
    $originalLocation = Get-Location
    try {
        Set-Location -Path $Config.workspace_path
        $agentResult = Invoke-MconOpenClawAgentSession -InvocationAgent $invocationAgent -SessionKey $sessionKey -Message $prompt -TimeoutSec 300
    } finally {
        Set-Location -Path $originalLocation
    }

    $stdoutText = ($agentResult.output | Out-String).Trim()
    $exitCode = $agentResult.exit_code

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
    if ($VerificationPaths.verification_kind -eq 'documentation' -and $parsedResult -and ($parsedResult.PSObject.Properties.Name -contains 'passed')) {
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
    $updatedTask = Set-MconTaskStatus -BaseUrl $leadConfig.base_url -Token $leadConfig.auth_token -BoardId $boardId -TaskId $TaskId -Status $resultingTaskStatus

    $reworkDispatch = $null
    if (-not $executionResult.passed) {
        $subagentUuid = Get-MconTaskSubagentUuid -Task $task
        $assignedAgentId = if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
            [string]$task.assigned_agent_id
        } else { $null }

        if ($assignedAgentId -and -not [string]::IsNullOrWhiteSpace($subagentUuid)) {
            $openClawRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $openClawRoot = if ($leadConfig.workspace_path) { Split-Path -Parent $leadConfig.workspace_path } else { $openClawRoot }
            $workerWorkspacePath = Join-Path $openClawRoot "workspace-mc-$assignedAgentId"

            if (Test-Path -LiteralPath $workerWorkspacePath) {
                try {
                    $workerConfig = Resolve-MconOpenClawConfig -WorkspacePath $workerWorkspacePath
                    $workerSpawnAgentId = if ($workerConfig.agents.list.Count -gt 0) { $workerConfig.agents.list[0].id } else { $null }
                    $workerLegacyName = if ($workerConfig.agents.list.Count -gt 0) { $workerConfig.agents.list[0].name.ToLower() } else { '' }

                    $sessionAgentNames = @()
                    foreach ($candidate in @($workerSpawnAgentId, $workerLegacyName)) {
                        if (-not [string]::IsNullOrWhiteSpace($candidate) -and ($sessionAgentNames -notcontains $candidate)) {
                            $sessionAgentNames += $candidate
                        }
                    }

                    $registeredSession = Resolve-MconRegisteredSubagentSession `
                        -OpenClawRoot $openClawRoot `
                        -AgentName $sessionAgentNames `
                        -SubagentUuid $subagentUuid `
                        -TaskId $TaskId

                    if (-not $registeredSession) {
                        $registeredSession = Resolve-MconRegisteredSubagentSessionByTask `
                            -OpenClawRoot $openClawRoot `
                            -AgentName $sessionAgentNames `
                            -TaskId $TaskId
                    }

                    if ($registeredSession) {
                        $childSessionKey = [string]$registeredSession.childSessionKey
                        $subagentAgentId = if ($registeredSession.PSObject.Properties.Name -contains 'registryAgentId') {
                            [string]$registeredSession.registryAgentId
                        } else { $workerSpawnAgentId }

                        $reworkPrompt = @"
# VERIFICATION FAILED — REWORK REQUIRED

Task $TaskId verification failed and requires rework.

## Verification Feedback
$commentMessage

## Work Contract
- Read the existing deliverables and fix only what needs fixing
- After completing rework, post a handoff comment and move the task to review
- If blocked, comment with the exact blocker and stop
"@

                        $diagnosticsDir = Join-Path $taskBundlePaths.evidence_directory 'session-dispatch'
                        $deferredPayload = [ordered]@{
                            workspace_path        = [string]$leadConfig.workspace_path
                            invocation_agent      = $subagentAgentId
                            session_key           = $childSessionKey
                            message               = $reworkPrompt
                            task_id               = $TaskId
                            dispatch_type         = 'rework'
                            timeout_seconds       = 300
                            temperature           = 0
                            initial_delay_seconds = 0
                        }
                        $response = Start-MconDeferredSessionDispatch `
                            -WorkspacePath ([string]$leadConfig.workspace_path) `
                            -MconScriptPath $MconScriptPath `
                            -DiagnosticsDir $diagnosticsDir `
                            -TaskId $TaskId `
                            -Payload $deferredPayload
                        $reworkDispatch = [ordered]@{
                            ok          = $true
                            session_key = $childSessionKey
                            agent_id    = $subagentAgentId
                            queued      = $true
                            dispatch    = $response
                        }
                    } else {
                        $reworkDispatch = [ordered]@{
                            ok     = $false
                            reason = 'no_registered_session'
                            note   = 'Could not find a registered subagent session for rework dispatch.'
                        }
                    }
                } catch {
                    $reworkDispatch = [ordered]@{
                        ok    = $false
                        error = $_.Exception.Message
                    }
                }
            } else {
                $reworkDispatch = [ordered]@{
                    ok     = $false
                    reason = 'worker_workspace_not_found'
                    note   = "Worker workspace not found: $workerWorkspacePath"
                }
            }
        } else {
            $reworkDispatch = [ordered]@{
                ok     = $false
                reason = 'no_assignment'
                note   = 'Task has no assigned agent or subagent UUID; cannot dispatch rework.'
            }
        }
    }

    $closureDispatch = $null
    if ($executionResult.passed -and $updatedTask.status -eq 'done') {
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
        rework_dispatch = $reworkDispatch
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
    $updatedTask = Set-MconTaskStatus -BaseUrl $leadConfig.base_url -Token $leadConfig.auth_token -BoardId $boardId -TaskId $TaskId -Status 'in_progress'

    $reworkDispatch = $null
    $subagentUuid = Get-MconTaskSubagentUuid -Task $task
    $assignedAgentId = if ($task.PSObject.Properties.Name -contains 'assigned_agent_id' -and $task.assigned_agent_id) {
        [string]$task.assigned_agent_id
    } else { $null }

    if ($assignedAgentId -and -not [string]::IsNullOrWhiteSpace($subagentUuid)) {
        $openClawRoot = Split-Path -Parent $leadConfig.workspace_path
        $workerWorkspacePath = Join-Path $openClawRoot "workspace-mc-$assignedAgentId"

        if (Test-Path -LiteralPath $workerWorkspacePath) {
            try {
                $workerConfig = Resolve-MconOpenClawConfig -WorkspacePath $workerWorkspacePath
                $workerSpawnAgentId = if ($workerConfig.agents.list.Count -gt 0) { $workerConfig.agents.list[0].id } else { $null }
                $workerLegacyName = if ($workerConfig.agents.list.Count -gt 0) { $workerConfig.agents.list[0].name.ToLower() } else { '' }

                $sessionAgentNames = @()
                foreach ($candidate in @($workerSpawnAgentId, $workerLegacyName)) {
                    if (-not [string]::IsNullOrWhiteSpace($candidate) -and ($sessionAgentNames -notcontains $candidate)) {
                        $sessionAgentNames += $candidate
                    }
                }

                $registeredSession = Resolve-MconRegisteredSubagentSession `
                    -OpenClawRoot $openClawRoot `
                    -AgentName $sessionAgentNames `
                    -SubagentUuid $subagentUuid `
                    -TaskId $TaskId

                if (-not $registeredSession) {
                    $registeredSession = Resolve-MconRegisteredSubagentSessionByTask `
                        -OpenClawRoot $openClawRoot `
                        -AgentName $sessionAgentNames `
                        -TaskId $TaskId
                }

                if ($registeredSession) {
                    $childSessionKey = [string]$registeredSession.childSessionKey
                    $subagentAgentId = if ($registeredSession.PSObject.Properties.Name -contains 'registryAgentId') {
                        [string]$registeredSession.registryAgentId
                    } else { $workerSpawnAgentId }

                    $reworkPrompt = @"
# VERIFICATION FAILED — REWORK REQUIRED

Task $TaskId verification failed and requires rework.

## Verification Feedback
$Message

## Work Contract
- Read the existing deliverables and fix only what needs fixing
- After completing rework, post a handoff comment and move the task to review
- If blocked, comment with the exact blocker and stop
"@

                    $mconScriptPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'mcon.ps1'
                    $taskBundlePaths = Get-MconVerifyTaskBundlePaths -LeadWorkspacePath $leadConfig.workspace_path -TaskId $TaskId
                    $diagnosticsDir = Join-Path $taskBundlePaths.evidence_directory 'session-dispatch'
                    $deferredPayload = [ordered]@{
                        workspace_path        = [string]$leadConfig.workspace_path
                        invocation_agent      = $subagentAgentId
                        session_key           = $childSessionKey
                        message               = $reworkPrompt
                        task_id               = $TaskId
                        dispatch_type         = 'rework'
                        timeout_seconds       = 300
                        temperature           = 0
                        initial_delay_seconds = 0
                    }
                    $response = Start-MconDeferredSessionDispatch `
                        -WorkspacePath ([string]$leadConfig.workspace_path) `
                        -MconScriptPath $mconScriptPath `
                        -DiagnosticsDir $diagnosticsDir `
                        -TaskId $TaskId `
                        -Payload $deferredPayload
                    $reworkDispatch = [ordered]@{
                        ok          = $true
                        session_key = $childSessionKey
                        agent_id    = $subagentAgentId
                        queued      = $true
                        dispatch    = $response
                    }
                }
            } catch {
                $reworkDispatch = [ordered]@{
                    ok    = $false
                    error = $_.Exception.Message
                }
            }
        }
    }

    return [ordered]@{
        ok = $true
        task_id = $TaskId
        resulting_task_status = $updatedTask.status
        rework_dispatch = $reworkDispatch
        comment_id = if ($comment.PSObject.Properties.Name -contains 'id') { $comment.id } else { $null }
        task = $updatedTask
    }
}

Export-ModuleMember -Function Invoke-MconVerifyRun, Invoke-MconVerifyFail
