<#
.SYNOPSIS
    Daily conversation review utility job - MVP test script.

.DESCRIPTION
    Compiles conversation context and creates a daily review task.
    This is a simple test implementation for the utility jobs MVP.
#>

[CmdletBinding()]
param(
    [string]$BoardId,
    [string]$AgentId,
    [string]$ExtraNote
)

# Simple logging
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logDir = "$HOME/.openclaw/logs/jobs"
$logFile = "$logDir/job-$(Get-Date -Format 'yyyyMMdd').log"

# Ensure log directory exists
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$message = @"
[$timestamp] Daily conversation review executed.
  BoardId: $BoardId
  AgentId: $AgentId
  ExtraNote: $ExtraNote
  Working directory: $PWD
"@

# Write to stdout (captured by cron) and to a separate file
Write-Output $message
Add-Content -Path $logFile -Value $message

# Simulate some work
Start-Sleep -Seconds 2

Write-Output "[$timestamp] Review complete."
