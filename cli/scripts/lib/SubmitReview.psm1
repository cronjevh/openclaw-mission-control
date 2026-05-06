function Resolve-MconVerificationArtifactPath {
    param(
        [Parameter(Mandatory)][string]$DeliverablesDir,
        [Parameter(Mandatory)][string]$TaskId,
        [string]$TaskTitle,
        $TaskData = $null
    )

    if ($TaskData) {
        if ($TaskData.PSObject.Properties.Name -contains 'lead_handoff') {
            $contract = $TaskData.lead_handoff
            if ($contract -and $contract.PSObject.Properties.Name -contains 'exact_output_contract') {
                $outputContract = $contract.exact_output_contract
                if ($outputContract -and $outputContract.PSObject.Properties.Name -contains 'required_verification_artifact_path') {
                    $path = [string]$outputContract.required_verification_artifact_path
                    if (-not [string]::IsNullOrWhiteSpace($path)) {
                        return $path
                    }
                }
            }
        }

        if ($TaskData.PSObject.Properties.Name -contains 'task_context') {
            $tc = $TaskData.task_context
            if ($tc -and $tc.PSObject.Properties.Name -contains 'task_bundle_paths') {
                $paths = $tc.task_bundle_paths
                if ($paths -and $paths.PSObject.Properties.Name -contains 'deliverables_directory') {
                    $delDir = [string]$paths.deliverables_directory
                    if (-not [string]::IsNullOrWhiteSpace($delDir)) {
                        return Resolve-MconVerificationArtifactPath -DeliverablesDir $delDir -TaskId $TaskId -TaskTitle $TaskTitle
                    }
                }
            }
        }
    }

    $title = if ($TaskTitle) { $TaskTitle } else { '' }
    if ($title -match 'plan|planning|document|documentation|note|strategy|report|analysis') {
        return Join-Path $DeliverablesDir "evaluate-$TaskId.json"
    }

    return Join-Path $DeliverablesDir "verify-$TaskId.ps1"
}

function Resolve-MconPrimaryDeliverablePath {
    param(
        [Parameter(Mandatory)][string]$DeliverablesDir,
        [Parameter(Mandatory)][string]$TaskId
    )

    if (-not (Test-Path -LiteralPath $DeliverablesDir)) {
        return $null
    }

    $verificationPatterns = @(
        "verify-$TaskId.ps1"
        "evaluate-$TaskId.json"
    )

    $candidates = @(
        Get-ChildItem -LiteralPath $DeliverablesDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $name = $_.Name
                if ($name.StartsWith('.')) { return $false }
                foreach ($pattern in $verificationPatterns) {
                    if ($name -eq $pattern) { return $false }
                }
                return $true
            }
    )

    if ($candidates.Count -eq 1) {
        return $candidates[0].FullName
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $sorted = @($candidates | Sort-Object Length -Descending)
    return $sorted[0].FullName
}

function Test-MconSubmitReviewReadiness {
    param(
        [Parameter(Mandatory)][string]$DeliverablesDir,
        [Parameter(Mandatory)][string]$VerificationArtifactPath,
        [string]$PrimaryDeliverablePath
    )

    $leadWorkspaceNote = " Deliverables must be placed in the LEAD workspace task bundle directory, not your local worker workspace. Your workspace is for experiments only."

    if (-not (Test-Path -LiteralPath $DeliverablesDir)) {
        return [ordered]@{
            ready  = $false
            code   = 'missing_deliverables_directory'
            reason = "Cannot submit task for review: deliverables directory does not exist at $DeliverablesDir.$leadWorkspaceNote"
        }
    }

    $dirItem = Get-Item -LiteralPath $DeliverablesDir
    if (-not $dirItem.PSIsContainer) {
        return [ordered]@{
            ready  = $false
            code   = 'missing_deliverables_directory'
            reason = "Cannot submit task for review: deliverables path is not a directory: $DeliverablesDir.$leadWorkspaceNote"
        }
    }

    if ([string]::IsNullOrWhiteSpace($PrimaryDeliverablePath)) {
        return [ordered]@{
            ready  = $false
            code   = 'missing_primary_deliverable'
            reason = "Cannot submit task for review: no primary deliverable found in deliverables directory.$leadWorkspaceNote"
        }
    }

    if (-not (Test-Path -LiteralPath $PrimaryDeliverablePath)) {
        return [ordered]@{
            ready  = $false
            code   = 'missing_primary_deliverable'
            reason = "Cannot submit task for review: primary deliverable not found at $PrimaryDeliverablePath.$leadWorkspaceNote"
        }
    }

    $primaryItem = Get-Item -LiteralPath $PrimaryDeliverablePath
    if ($primaryItem.PSIsContainer) {
        return [ordered]@{
            ready  = $false
            code   = 'missing_primary_deliverable'
            reason = "Cannot submit task for review: primary deliverable path is a directory, not a file: $PrimaryDeliverablePath.$leadWorkspaceNote"
        }
    }

    if ($primaryItem.Length -eq 0) {
        return [ordered]@{
            ready  = $false
            code   = 'empty_primary_deliverable'
            reason = "Cannot submit task for review: primary deliverable is empty (0 bytes): $PrimaryDeliverablePath.$leadWorkspaceNote"
        }
    }

    if (-not (Test-Path -LiteralPath $VerificationArtifactPath)) {
        return [ordered]@{
            ready  = $false
            code   = 'missing_verification_artifact'
            reason = "Cannot submit task for review: required verification artifact is missing at $VerificationArtifactPath.$leadWorkspaceNote"
        }
    }

    $verifyItem = Get-Item -LiteralPath $VerificationArtifactPath
    if ($verifyItem.PSIsContainer) {
        return [ordered]@{
            ready  = $false
            code   = 'missing_verification_artifact'
            reason = "Cannot submit task for review: verification artifact path is a directory, not a file: $VerificationArtifactPath.$leadWorkspaceNote"
        }
    }

    if ($verifyItem.Length -eq 0) {
        return [ordered]@{
            ready  = $false
            code   = 'empty_verification_artifact'
            reason = "Cannot submit task for review: verification artifact is empty (0 bytes): $VerificationArtifactPath.$leadWorkspaceNote"
        }
    }

    return [ordered]@{
        ready = $true
        code  = 'ready'
        reason = 'All deliverables present and non-empty.'
    }
}

function Invoke-MconSubmitReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TaskId,
        [string]$Message
    )

    $baseUrl = $Config.base_url.TrimEnd('/')
    $authToken = $Config.auth_token
    $boardId = $Config.board_id
    $workspacePath = $Config.workspace_path

    $encodedBoardId = [uri]::EscapeDataString($boardId)
    $encodedTaskId = [uri]::EscapeDataString($TaskId)
    $taskUri = "$baseUrl/api/v1/agent/boards/$encodedBoardId/tasks/$encodedTaskId"

    $task = Invoke-MconApi -Method Get -Uri $taskUri -Token $authToken

    $taskTitle = if ($task.PSObject.Properties.Name -contains 'title') { [string]$task.title } else { '' }

    $deliverablesDir = $null
    $taskData = $null

    # Deliverables must be in the lead workspace task bundle directory
    $leadWorkspacePath = "/home/cronjev/.openclaw/workspace-lead-$boardId"
    $leadTaskBundlePath = Join-Path $leadWorkspacePath "tasks/$TaskId"
    $deliverablesDir = Join-Path $leadTaskBundlePath 'deliverables'

    # Update taskData.json to reflect the correct lead workspace path
    $taskDataPath = Join-Path $leadTaskBundlePath 'taskData.json'
    if (Test-Path -LiteralPath $taskDataPath) {
        $taskData = Get-Content -LiteralPath $taskDataPath -Raw | ConvertFrom-Json -Depth 50

        # Update deliverables_directory in taskData to point to lead workspace
        if ($taskData.PSObject.Properties.Name -contains 'deliverables_directory') {
            $taskData.deliverables_directory = $deliverablesDir
        }

        # Update task_context.task_bundle_paths if present
        if ($taskData.PSObject.Properties.Name -contains 'task_context') {
            $tc = $taskData.task_context
            if ($tc -and $tc.PSObject.Properties.Name -contains 'task_bundle_paths') {
                if ($null -eq $tc.task_bundle_paths) {
                    $tc.task_bundle_paths = [ordered]@{}
                }
                $tc.task_bundle_paths.deliverables_directory = $deliverablesDir
                $tc.task_bundle_paths.evidence_directory = Join-Path $leadTaskBundlePath 'evidence'
            }
        }

        # Save updated taskData back
        $taskData | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $taskDataPath -Encoding UTF8
    }

    $verificationArtifactPath = Resolve-MconVerificationArtifactPath `
        -DeliverablesDir $deliverablesDir `
        -TaskId $TaskId `
        -TaskTitle $taskTitle `
        -TaskData $taskData

    $primaryDeliverablePath = Resolve-MconPrimaryDeliverablePath `
        -DeliverablesDir $deliverablesDir `
        -TaskId $TaskId

    $readiness = Test-MconSubmitReviewReadiness `
        -DeliverablesDir $deliverablesDir `
        -VerificationArtifactPath $verificationArtifactPath `
        -PrimaryDeliverablePath $primaryDeliverablePath

    $details = [ordered]@{
        task_id                    = $TaskId
        task_title                 = $taskTitle
        deliverables_directory     = $deliverablesDir
        primary_deliverable_path   = $primaryDeliverablePath
        verification_artifact_path = $verificationArtifactPath
    }

    if (-not $readiness.ready) {
        return [ordered]@{
            ok      = $false
            code    = $readiness.code
            message = $readiness.reason
            details = $details
        }
    }

    $handoffMessage = if ($Message) {
        $Message
    } else {
        $lines = @(
            "Submitting task for review."
            ''
            'Deliverables:'
            "- Primary: $primaryDeliverablePath"
            "- Verification: $verificationArtifactPath"
        )
        $lines -join "`n"
    }

    $commentsUri = "$taskUri/comments"
    Invoke-MconApi -Method Post -Uri $commentsUri -Token $authToken -Body @{ message = $handoffMessage } | Out-Null

    # Use LOCAL_AUTH_TOKEN (user endpoint) for status transitions
    $userTaskUri = "$baseUrl/api/v1/boards/$encodedBoardId/tasks/$encodedTaskId"
    $updatedTask = Invoke-MconLocalAuthApi -Method Patch -Uri $userTaskUri -Body @{ status = 'review' }

    return [ordered]@{
        ok         = $true
        code       = 'submitted'
        message    = 'Task submitted for review.'
        details    = $details
        task       = $updatedTask
    }
}

Export-ModuleMember -Function Invoke-MconSubmitReview
