function Get-MconOpenClawGatewayConfig {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $openClawRoot = Split-Path -Path $WorkspacePath -Parent
    $configPath = Join-Path $openClawRoot 'openclaw.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "OpenClaw config not found: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 50
    $port = $config.gateway.port
    $token = $config.gateway.auth.token
    $chatEnabled = $config.gateway.http.endpoints.chatCompletions.enabled

    if (-not $port) { throw "Gateway port missing in $configPath" }
    if (-not $token) { throw "Gateway auth token missing in $configPath" }
    if (-not $chatEnabled) { throw "Gateway chat completions endpoint is disabled in $configPath" }

    return [pscustomobject]@{
        port  = [int]$port
        token = [string]$token
    }
}

function New-MconOpenClawSessionDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Write-MconOpenClawSessionJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Data
    )

    $Data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function ConvertTo-MconOpenClawBashSingleQuotedString {
    param(
        [Parameter(Mandatory)][string]$Value
    )

    return "'" + ($Value -replace "'", "'""'""'") + "'"
}

function Get-MconAgentTaskSessionKey {
    param(
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)][string]$TaskId
    )

    return "agent:${InvocationAgent}:task:$TaskId"
}

function New-MconLeadClosureDirective {
    param(
        [Parameter(Mandatory)]$TaskRefs
    )

    $doneTaskRefs = @($TaskRefs | Where-Object { $_.status -eq 'done' })
    if ($doneTaskRefs.Count -eq 0) {
        return $null
    }

    $taskLines = @()
    foreach ($taskRef in $doneTaskRefs) {
        $taskLines += "- Task $($taskRef.id): $($taskRef.title)"
        $taskLines += "  task context: [taskData.json]($($taskRef.taskDataPath))"
        $taskLines += "  deliverables: [deliverables/]($($taskRef.deliverablesDir))"
        $taskLines += "  evidence: [evidence/]($($taskRef.evidenceDir))"
    }

    return (@'
## TASK-SPECIFIC CLOSURE DIRECTIVE

The following task(s) are already in `done` and require post-completion follow-through in this turn:
{0}

Before ending the turn, execute this closure protocol for each completed task:
1. Scan for implied follow-up work.
   - Read the completed task's description, comments, and evidence.
   - Ask whether the completion creates, enables, or necessitates any new board task.
   - If yes, create the follow-up task(s) before replying.
2. Check dependent tasks.
   - For each task that lists the completed task in `depends_on_task_ids`, add a dependency-resolution notice.
   - If the dependent task is now unblocked and the next step is clear, prepare it for reassessment.
3. Ingest reusable patterns.
   - Capture reusable process, script, decision, or operational improvements in the proper durable surface.
   - Use the wiki for broadly reusable concepts or syntheses, and record durable updates in `MEMORY.md` where appropriate.
4. Capture self-improvement items.
   - Log mistakes, better approaches, or systemic friction in the appropriate learning surface.
   - Promote durable behavior to `SOUL.md`, workflow rules to `AGENTS.md`, and tool rules to `TOOLS.md` when justified.
5. Update memory-wiki
   - Review any memory-wiki updates made by the worker agent if any.
   - Update memory wiki content based on the results, discoveries and other output of the task. 
6. Post a concise factual closure summary comment.
  - Include deliverables, follow-up tasks, wiki ingestion, and any remaining risk or open question.

Keep the control-plane boundary intact: you may create follow-up tasks or leave breadcrumbs here, but defer any fresh assignment or work-start decision to the next gated heartbeat authorization.
'@ -f ($taskLines -join "`n"))
}

function Send-MconOpenClawSessionMessage {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)][string]$SessionKey,
        [Parameter(Mandatory)][string]$Message,
        [int]$TimeoutSec = 120,
        [string]$LogPath = $null,
        [string]$TaskId = $null,
        [string]$DispatchType = $null,
        [string]$QueueItemId = $null,
        [double]$Temperature = -1,
        [int]$MaxTokens = 0,
        [hashtable]$AdditionalBody = $null
    )

    $gateway = Get-MconOpenClawGatewayConfig -WorkspacePath $WorkspacePath
    $uri = "http://127.0.0.1:$($gateway.port)/v1/chat/completions"
    $headers = @{
        Authorization            = "Bearer $($gateway.token)"
        'x-openclaw-session-key' = $SessionKey
    }
    $body = [ordered]@{
        model    = "openclaw/$InvocationAgent"
        messages = @(
            @{
                role    = 'user'
                content = $Message
            }
        )
    }
    if ($Temperature -ge 0) {
        $body.temperature = $Temperature
    }
    if ($MaxTokens -gt 0) {
        $body.max_tokens = $MaxTokens
    }
    if ($AdditionalBody) {
        foreach ($key in $AdditionalBody.Keys) {
            $body[$key] = $AdditionalBody[$key]
        }
    }

    $logContext = @(
        "gateway_chat",
        "task=$TaskId",
        "dispatch_type=$DispatchType",
        "queue_item=$QueueItemId",
        "session_key=$SessionKey",
        "timeout_sec=$TimeoutSec"
    ) -join ' '
    $startTime = Get-Date
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-MconQueueLog -Path $LogPath -Message "$logContext begin"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 10) -TimeoutSec $TimeoutSec
        $elapsedMs = ((Get-Date) - $startTime).TotalMilliseconds
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-MconQueueLog -Path $LogPath -Message "$logContext complete elapsed_ms=$([math]::Round($elapsedMs))"
        }
        return $response
    } catch {
        $elapsedMs = ((Get-Date) - $startTime).TotalMilliseconds
        $errorText = ($_ | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-MconQueueLog -Path $LogPath -Message "$logContext failed elapsed_ms=$([math]::Round($elapsedMs)) error=$errorText"
        }
        throw "gateway chat failed task=$TaskId dispatch_type=$DispatchType queue_item=$QueueItemId session_key=$SessionKey timeout_sec=$TimeoutSec elapsed_ms=$([math]::Round($elapsedMs)): $errorText"
    }
}

function Start-MconDeferredSessionDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$MconScriptPath,
        [Parameter(Mandatory)][string]$DiagnosticsDir,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][hashtable]$Payload
    )

    $jobsDir = New-MconOpenClawSessionDirectory -Path (Join-Path $DiagnosticsDir 'session-dispatch-jobs')
    $jobId = [guid]::NewGuid().Guid
    $payloadPath = Join-Path $jobsDir "$TaskId-$jobId-payload.json"
    $resultPath = Join-Path $jobsDir "$TaskId-$jobId-result.json"
    $stdoutLog = Join-Path $jobsDir "$TaskId-$jobId-stdout.log"
    $stderrLog = Join-Path $jobsDir "$TaskId-$jobId-stderr.log"

    $Payload['job_id'] = $jobId
    $Payload['payload_path'] = $payloadPath
    $Payload['result_path'] = $resultPath
    $Payload['stdout_log'] = $stdoutLog
    $Payload['stderr_log'] = $stderrLog
    $Payload['created_at'] = (Get-Date).ToUniversalTime().ToString('o')

    Write-MconOpenClawSessionJson -Path $payloadPath -Data $Payload | Out-Null

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    if (-not ($IsLinux -or $IsMacOS)) {
        $process = Start-Process `
            -FilePath $pwshPath `
            -ArgumentList @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $MconScriptPath, 'workflow', 'session-dispatch', '--process', '--payload', $payloadPath) `
            -WorkingDirectory $WorkspacePath `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog `
            -PassThru
    } else {
        $bashPath = (Get-Command bash -ErrorAction Stop).Source
        $setsidPath = $null
        try {
            $setsidPath = (Get-Command setsid -ErrorAction Stop).Source
        } catch {
            $setsidPath = $null
        }

        $commandWords = @()
        if (-not [string]::IsNullOrWhiteSpace($setsidPath)) {
            $commandWords += (ConvertTo-MconOpenClawBashSingleQuotedString -Value $setsidPath)
        }
        $commandWords += (ConvertTo-MconOpenClawBashSingleQuotedString -Value $pwshPath)
        $commandWords += @(
            '-NoProfile',
            '-NoLogo',
            '-NonInteractive',
            '-File',
            (ConvertTo-MconOpenClawBashSingleQuotedString -Value $MconScriptPath),
            'workflow',
            'session-dispatch',
            '--process',
            '--payload',
            (ConvertTo-MconOpenClawBashSingleQuotedString -Value $payloadPath)
        )

        $launchCommand = @(
            "cd {0} || exit 1" -f (ConvertTo-MconOpenClawBashSingleQuotedString -Value $WorkspacePath)
            "nohup {0} </dev/null >> {1} 2>> {2} &" -f (
                ($commandWords -join ' '),
                (ConvertTo-MconOpenClawBashSingleQuotedString -Value $stdoutLog),
                (ConvertTo-MconOpenClawBashSingleQuotedString -Value $stderrLog)
            )
            'echo $!'
        ) -join "`n"

        $launchOutput = & $bashPath '-lc' $launchCommand 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errorText = ($launchOutput | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($errorText)) {
                $errorText = "bash launcher exited with code $LASTEXITCODE"
            }
            throw $errorText
        }

        $pidLine = @(
            $launchOutput |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -match '^\d+$' } |
            Select-Object -Last 1
        )
        if ($pidLine.Count -eq 0) {
            $errorText = ($launchOutput | Out-String).Trim()
            throw "Detached session-dispatch launch did not return a PID. Output: $errorText"
        }

        $process = [pscustomobject]@{
            Id = [int]$pidLine[0]
        }
    }

    return [ordered]@{
        queued      = $true
        jobId       = $jobId
        pid         = $process.Id
        payloadPath = $payloadPath
        resultPath  = $resultPath
        stdoutLog   = $stdoutLog
        stderrLog   = $stderrLog
    }
}

function Invoke-MconDeferredSessionDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PayloadPath
    )

    $payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $resultPath = [string]$payload.result_path
    $result = $null
    $response = $null

    try {
        $initialDelaySeconds = if ($payload.PSObject.Properties.Name -contains 'initial_delay_seconds') { [int]$payload.initial_delay_seconds } else { 0 }
        if ($initialDelaySeconds -gt 0) {
            Start-Sleep -Seconds $initialDelaySeconds
        }

        $timeoutSeconds = if ($payload.PSObject.Properties.Name -contains 'timeout_seconds') { [int]$payload.timeout_seconds } else { 120 }
        $temperature = if ($payload.PSObject.Properties.Name -contains 'temperature') { [double]$payload.temperature } else { -1 }
        $maxTokens = if ($payload.PSObject.Properties.Name -contains 'max_tokens') { [int]$payload.max_tokens } else { 0 }

        $response = Send-MconOpenClawSessionMessage `
            -WorkspacePath ([string]$payload.workspace_path) `
            -InvocationAgent ([string]$payload.invocation_agent) `
            -SessionKey ([string]$payload.session_key) `
            -Message ([string]$payload.message) `
            -TaskId ([string]$payload.task_id) `
            -DispatchType ([string]$payload.dispatch_type) `
            -TimeoutSec $timeoutSeconds `
            -Temperature $temperature `
            -MaxTokens $maxTokens

        $result = [ordered]@{
            ok             = $true
            mode           = 'session_dispatch'
            async          = $true
            taskId         = if ($payload.PSObject.Properties.Name -contains 'task_id') { [string]$payload.task_id } else { $null }
            dispatchType   = if ($payload.PSObject.Properties.Name -contains 'dispatch_type') { [string]$payload.dispatch_type } else { $null }
            invocationAgent = if ($payload.PSObject.Properties.Name -contains 'invocation_agent') { [string]$payload.invocation_agent } else { $null }
            sessionKey     = if ($payload.PSObject.Properties.Name -contains 'session_key') { [string]$payload.session_key } else { $null }
            deferredDispatch = [ordered]@{
                jobId       = if ($payload.PSObject.Properties.Name -contains 'job_id') { [string]$payload.job_id } else { $null }
                payloadPath = $PayloadPath
                resultPath  = $resultPath
                stdoutLog   = if ($payload.PSObject.Properties.Name -contains 'stdout_log') { [string]$payload.stdout_log } else { $null }
                stderrLog   = if ($payload.PSObject.Properties.Name -contains 'stderr_log') { [string]$payload.stderr_log } else { $null }
                completedAt = (Get-Date).ToUniversalTime().ToString('o')
            }
            response = $response
        }
    } catch {
        $result = [ordered]@{
            ok               = $false
            phase            = 'session_dispatch'
            error            = $_.Exception.Message
            taskId           = if ($payload.PSObject.Properties.Name -contains 'task_id') { [string]$payload.task_id } else { $null }
            dispatchType     = if ($payload.PSObject.Properties.Name -contains 'dispatch_type') { [string]$payload.dispatch_type } else { $null }
            invocationAgent  = if ($payload.PSObject.Properties.Name -contains 'invocation_agent') { [string]$payload.invocation_agent } else { $null }
            sessionKey       = if ($payload.PSObject.Properties.Name -contains 'session_key') { [string]$payload.session_key } else { $null }
            deferredDispatch = [ordered]@{
                jobId       = if ($payload.PSObject.Properties.Name -contains 'job_id') { [string]$payload.job_id } else { $null }
                payloadPath = $PayloadPath
                resultPath  = $resultPath
                stdoutLog   = if ($payload.PSObject.Properties.Name -contains 'stdout_log') { [string]$payload.stdout_log } else { $null }
                stderrLog   = if ($payload.PSObject.Properties.Name -contains 'stderr_log') { [string]$payload.stderr_log } else { $null }
            }
            response = $response
        }
    }

    if ($resultPath) {
        Write-MconOpenClawSessionJson -Path $resultPath -Data $result | Out-Null
    }

    return $result
}

function Invoke-MconOpenClawAgentSession {
    param(
        [Parameter(Mandatory)][string]$InvocationAgent,
        [Parameter(Mandatory)][string]$SessionKey,
        [Parameter(Mandatory)][string]$Message,
        [int]$TimeoutSec = 300
    )

    $agentOutput = & openclaw agent --agent $InvocationAgent --session-id $SessionKey --message $Message --json --timeout $TimeoutSec --thinking off 2>&1
    return [ordered]@{
        exit_code = $LASTEXITCODE
        output    = ($agentOutput -join "`n")
    }
}

Export-ModuleMember -Function Get-MconOpenClawGatewayConfig, Get-MconAgentTaskSessionKey, New-MconLeadClosureDirective, Send-MconOpenClawSessionMessage, Start-MconDeferredSessionDispatch, Invoke-MconDeferredSessionDispatch, Invoke-MconOpenClawAgentSession
