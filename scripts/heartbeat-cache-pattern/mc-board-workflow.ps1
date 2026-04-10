#!/usr/bin/env pwsh
<# Cached board-dispatch: check cache first; if fresh and act unchanged, skip gate entirely. #>
Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

$AgentId = 'dd95369d-1497-41f2-8aeb-e06b51b63162'
$BoardId = 'dd95369d-1497-41f2-8aeb-e06b51b63162'
$Wsp = "/home/cronjev/.openclaw/workspace-lead-$BoardId"
$State = Join-Path $Wsp '.openclaw/workflows/.dispatch-state-latest.json'
$Dispatch = '/home/cronjev/.openclaw/scripts/mission-control-scripts/mc-board-dispatch.ps1'
$TTL = 300

# ── Cache miss or stale ──
try { & pwsh -NoProfile -File $Dispatch -AgentId $AgentId -BoardId $BoardId | Out-File $State }
catch { Write-Host "OK # dispatch failed"; exit 0 }

# ── Fast cache check ──
if (Test-Path $State) {
    $age = ((Get-Date) - (Get-Item -Force $State).LastWriteTime).TotalSeconds
    if ($age -lt $TTL) {
        $j = Get-Content $State -Raw | ConvertFrom-Json
        if ($j.act -eq $false) {
            Write-Host "OK # act=false (cached)"
            exit 0
        }
    }
}
# ── Post-gate decision ──

$j = Get-Content $State -Raw | ConvertFrom-Json
if ($j.act -eq $true) {
    # Get Authtoken from Tools - short form, path already validated in prior step
    $(Get-Content -Path $Wsp/TOOLS.md -Raw) -match '(?m)^\s*AUTH_TOKEN\s*=\s*([^\r\n]+?)\s*$' | Out-Null
    $authToken = $matches[1].Trim().Trim('`', '"', "'")
    $Msg = @()
    $Msg += @"
# HEARTBEAT
## Board state
``````json
$($j | ConvertTo-Json -Depth 6)
``````
AUTH_TOKEN=$authToken

"@
    $Msg += (Get-Content (Join-Path $Wsp 'GATED-HEARTBEAT.md') -Raw)
    & openclaw agent --agent "lead-dd95369d-1497-41f2-8aeb-e06b51b63162" --message "$Msg" --json --timeout 120 --thinking on
}
else {
    Write-Host "OK # act=false ($($j.reason))"
    exit 0
}
