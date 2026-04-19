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

function Get-MconPrimaryDeliverablePath {
    param(
        [Parameter(Mandatory)][string]$DeliverablesDirectory,
        [Parameter(Mandatory)][string]$TaskId
    )

    $files = @(
        Get-ChildItem -LiteralPath $DeliverablesDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "verify-$TaskId.ps1" -and $_.Name -ne "evaluate-$TaskId.json" }
    )

    if ($files.Count -eq 0) {
        throw "Primary deliverable not found in $DeliverablesDirectory"
    }
    if ($files.Count -gt 1) {
        throw "Expected exactly one primary deliverable in $DeliverablesDirectory, found $($files.Count)"
    }

    return $files[0].FullName
}

function Get-MconVerificationPaths {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)]$TaskBundlePaths
    )

    $deliverablesDir = $TaskBundlePaths.deliverables_directory
    $primaryDeliverablePath = Get-MconPrimaryDeliverablePath -DeliverablesDirectory $deliverablesDir -TaskId $TaskId

    if (Test-MconVerificationTaskLooksLikeDocs -Task $Task) {
        $verificationKind = 'documentation'
        $judgeSpecPath = Join-Path $deliverablesDir "evaluate-$TaskId.json"
        $verificationArtifactPath = Join-Path $deliverablesDir "verify-$TaskId.ps1"

        if (-not (Test-Path -LiteralPath $judgeSpecPath)) {
            throw "Judge spec not found: $judgeSpecPath"
        }
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
            verification_artifact_path = $verificationArtifactPath
            judge_spec_path = $judgeSpecPath
        }
    }

    $verificationArtifactPath = Join-Path $deliverablesDir "verify-$TaskId.ps1"
    if (-not (Test-Path -LiteralPath $verificationArtifactPath)) {
        throw "Verification script not found: $verificationArtifactPath"
    }

    return [ordered]@{
        verification_kind = 'deterministic'
        primary_deliverable_path = $primaryDeliverablePath
        verification_artifact_path = $verificationArtifactPath
        judge_spec_path = $null
    }
}

function Invoke-MconVerificationProcess {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)]$VerificationPaths,
        [Parameter(Mandatory)]$TaskBundlePaths
    )

    $evidenceDir = $TaskBundlePaths.evidence_directory
    if (-not (Test-Path -LiteralPath $evidenceDir)) {
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    }

    $verificationArtifactPath = $VerificationPaths.verification_artifact_path
    if ($VerificationPaths.verification_kind -eq 'documentation') {
        $stdout = & pwsh -NoProfile -File $verificationArtifactPath `
            -TaskId $TaskId `
            -DocumentPath $VerificationPaths.primary_deliverable_path `
            -JudgeSpecPath $VerificationPaths.judge_spec_path `
            -EvidenceDir $evidenceDir 2>&1
        $exitCode = $LASTEXITCODE
    } else {
        $stdout = & pwsh -NoProfile -File $verificationArtifactPath 2>&1
        $exitCode = $LASTEXITCODE
    }

    $stdoutText = ($stdout | Out-String).Trim()
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
        $EvidencePacket
    )

    $decision = if ($ExecutionResult.passed) { 'PASS' } else { 'FAIL' }
    $actionTaken = if ($ExecutionResult.passed) { 'moved to done' } else { 'returned to inbox for rework' }
    $resultPath = if ($ExecutionResult.validation_result_path) { $ExecutionResult.validation_result_path } else { 'none' }
    $stdoutSummary = if ([string]::IsNullOrWhiteSpace($ExecutionResult.stdout)) { 'none' } else { $ExecutionResult.stdout }
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
Action: $actionTaken
Resulting task status: $ResultingTaskStatus
Output: $stdoutSummary
"@
}

function Invoke-MconVerifyRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TaskId
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
    $executionResult = Invoke-MconVerificationProcess -TaskId $TaskId -VerificationPaths $verificationPaths -TaskBundlePaths $taskBundlePaths

    $resultingTaskStatus = if ($executionResult.passed) { 'done' } else { 'inbox' }
    $actionTaken = if ($executionResult.passed) { 'mark_done' } else { 'return_to_sender' }
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
        -EvidencePacket $evidencePacket

    $comment = Send-MconComment -BaseUrl $baseUrl -Token $authToken -BoardId $boardId -TaskId $TaskId -Message $commentMessage
    $updatedTask = Set-MconTaskStatus -BaseUrl $leadConfig.base_url -Token $leadConfig.auth_token -BoardId $boardId -TaskId $TaskId -Status $resultingTaskStatus

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
        comment_id = if ($comment.PSObject.Properties.Name -contains 'id') { $comment.id } else { $null }
        task = $updatedTask
    }
}

Export-ModuleMember -Function Invoke-MconVerifyRun
