param(
    [string]$TaskId = "TASK_ID",
    [Parameter(Mandatory = $true)]
    [string]$DocumentPath,
    [Parameter(Mandatory = $true)]
    [string]$JudgeSpecPath,
    [string]$EvidenceDir,
    [string]$Model = "step-3.5-flash-2603",
    [int]$TimeoutSeconds = 45,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$StepFunBaseUrl = "https://api.stepfun.ai/step_plan/v1"

function Get-StepFunApiKey {
    if (-not [string]::IsNullOrWhiteSpace($env:STEPFUN_API_KEY)) {
        return $env:STEPFUN_API_KEY.Trim()
    }

    $dotenvPath = "/home/cronjev/.openclaw/.env"
    if (-not (Test-Path -LiteralPath $dotenvPath)) {
        throw "STEPFUN_API_KEY is not set and $dotenvPath was not found."
    }

    $line = Get-Content -LiteralPath $dotenvPath | Where-Object {
        $_ -match '^\s*STEPFUN_API_KEY='
    } | Select-Object -First 1

    if (-not $line) {
        throw "STEPFUN_API_KEY is not set and was not found in $dotenvPath."
    }

    return (($line -split '=', 2)[1]).Trim()
}

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-EvidenceDir {
    param(
        [string]$ExplicitEvidenceDir,
        [Parameter(Mandatory = $true)][string]$JudgeSpecPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEvidenceDir)) {
        return Resolve-AbsolutePath -Path $ExplicitEvidenceDir
    }

    $derivedDir = Split-Path -Parent $JudgeSpecPath
    if ([string]::IsNullOrWhiteSpace($derivedDir)) {
        throw "Unable to derive evidence directory from judge spec path: $JudgeSpecPath"
    }

    return Resolve-AbsolutePath -Path $derivedDir
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Cannot write file without a parent directory: $Path"
    }

    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content)
}

function ConvertTo-PrettyJson {
    param([Parameter(Mandatory = $true)]$InputObject)

    return ($InputObject | ConvertTo-Json -Depth 100)
}

function Parse-JudgeResponse {
    param([AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }

    try {
        return $Content | ConvertFrom-Json -Depth 100
    } catch {
        return $null
    }
}

function New-JudgePrompt {
    param(
        [Parameter(Mandatory = $true)]$JudgeSpec,
        [Parameter(Mandatory = $true)][string]$DocumentText,
        [Parameter(Mandatory = $true)][string]$DocumentPath,
        [Parameter(Mandatory = $true)][string]$TaskId
    )

    $criteriaJson = ConvertTo-PrettyJson -InputObject $JudgeSpec.criteria
    $outputSchemaJson = ConvertTo-PrettyJson -InputObject $JudgeSpec.output_schema
    $taskSummary = if ($JudgeSpec.task_summary) { [string]$JudgeSpec.task_summary } else { "" }
    $instructions = if ($JudgeSpec.instructions) { [string]$JudgeSpec.instructions } else { "" }
    $antiCheatLines = @($JudgeSpec.anti_cheat_rules | ForEach-Object { "- $_" }) -join "`n"

@"
You are a strict verification judge.

Return exactly one JSON object and nothing else.
Do not explain outside the JSON.

Task ID: $TaskId
Document path: $DocumentPath

Task summary:
$taskSummary

Judge instructions:
$instructions

Anti-cheat rules:
$antiCheatLines

Criteria JSON:
$criteriaJson

Required output schema:
$outputSchemaJson

Document to evaluate:
<<<DOCUMENT
$DocumentText
DOCUMENT
"@
}

if (-not (Test-Path -LiteralPath $DocumentPath)) {
    throw "Document path not found: $DocumentPath"
}

if (-not (Test-Path -LiteralPath $JudgeSpecPath)) {
    throw "Judge spec path not found: $JudgeSpecPath"
}

$documentPathAbs = Resolve-AbsolutePath -Path $DocumentPath
$judgeSpecPathAbs = Resolve-AbsolutePath -Path $JudgeSpecPath
$effectiveEvidenceDir = Resolve-EvidenceDir -ExplicitEvidenceDir $EvidenceDir -JudgeSpecPath $judgeSpecPathAbs

if (-not (Test-Path -LiteralPath $effectiveEvidenceDir)) {
    New-Item -ItemType Directory -Path $effectiveEvidenceDir -Force | Out-Null
}

$documentText = Get-Content -LiteralPath $documentPathAbs -Raw
$judgeSpec = Get-Content -LiteralPath $judgeSpecPathAbs -Raw | ConvertFrom-Json -Depth 100
$prompt = New-JudgePrompt -JudgeSpec $judgeSpec -DocumentText $documentText -DocumentPath $documentPathAbs -TaskId $TaskId

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$promptCopyPath = Join-Path $effectiveEvidenceDir ("validation-prompt-{0}.txt" -f $TaskId)
$rawOutputPath = Join-Path $effectiveEvidenceDir ("validation-raw-{0}-{1}.json" -f $TaskId, $timestamp)
$finalResultPath = Join-Path $effectiveEvidenceDir ("validation-result-{0}.json" -f $TaskId)

Write-TextFile -Path $promptCopyPath -Content $prompt

$requestUri = "$StepFunBaseUrl/chat/completions"
$requestBody = @{
    model = $Model
    messages = @(
        @{
            role = "user"
            content = $prompt
        }
    )
    temperature = 0
}

$response = $null
$rawResponseText = ""
$judgeContent = ""
$judgeResult = $null
$failureReason = $null
$exitCode = 1

try {
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $requestUri `
        -Headers @{
            Authorization = "Bearer $(Get-StepFunApiKey)"
            "Content-Type" = "application/json"
        } `
        -Body ($requestBody | ConvertTo-Json -Depth 20) `
        -TimeoutSec $TimeoutSeconds

    $rawResponseText = $response | ConvertTo-Json -Depth 100
    Write-TextFile -Path $rawOutputPath -Content $rawResponseText

    if ($response.choices -and $response.choices.Count -gt 0) {
        $message = $response.choices[0].message
        if ($message -and $message.content) {
            if ($message.content -is [System.Array]) {
                $judgeContent = (($message.content | ForEach-Object {
                    if ($_ -is [string]) {
                        $_
                    } elseif ($_.text) {
                        [string]$_.text
                    }
                }) -join "")
            } else {
                $judgeContent = [string]$message.content
            }
        }
    }

    $judgeResult = Parse-JudgeResponse -Content $judgeContent
    $exitCode = 0
} catch {
    $failureReason = "stepfun direct request failed"
    $rawResponseText = ($_ | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($rawResponseText)) {
        Write-TextFile -Path $rawOutputPath -Content $rawResponseText
    }
}

if ($exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($judgeContent)) {
    $failureReason = "judge response did not contain message content"
}

if ($exitCode -eq 0 -and $null -eq $judgeResult) {
    $failureReason = "unable to parse judge JSON result"
}

$passed = $false
if ($null -ne $judgeResult -and ($judgeResult.PSObject.Properties.Name -contains "passed")) {
    $passed = [bool]$judgeResult.passed
} elseif ($exitCode -eq 0 -and $null -eq $failureReason) {
    $failureReason = "judge output did not contain a passed field"
}

$result = [pscustomobject]@{
    task_id = $TaskId
    validator_kind = "llm_judge_wrapper"
    validator_entrypoint = $MyInvocation.MyCommand.Path
    transport = "stepfun_direct_chat_completions"
    model = $Model
    target_artifact_path = $documentPathAbs
    validation_input_path = $judgeSpecPathAbs
    evidence_dir = $effectiveEvidenceDir
    executed_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    command_exit_code = [int]$exitCode
    request_uri = $requestUri
    raw_output_path = $rawOutputPath
    prompt_copy_path = $promptCopyPath
    parsed = ($null -ne $judgeResult)
    passed = $passed
    failure_reason = $failureReason
    judge_result = $judgeResult
}

Write-TextFile -Path $finalResultPath -Content (ConvertTo-PrettyJson -InputObject $result)

if ($PassThru) {
    $result
}

if ($passed) {
    exit 0
}

if ($null -ne $judgeResult) {
    exit 1
}

exit 2
