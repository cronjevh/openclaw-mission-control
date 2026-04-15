#!/usr/bin/env pwsh
<# Cached board-dispatch: check cache first; if fresh and act unchanged, skip gate entirely. #>
param(
    [switch]$ProcessQueue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AgentId = 'dd95369d-1497-41f2-8aeb-e06b51b63162'
$BoardId = 'dd95369d-1497-41f2-8aeb-e06b51b63162'
$Wsp = "/home/cronjev/.openclaw/workspace-lead-$BoardId"
$State = Join-Path $Wsp '.openclaw/workflows/.dispatch-state-latest.json'
$SharedScriptsRoot = '/home/cronjev/mission-control-tfsmrt/scripts'
$Dispatch = Join-Path $SharedScriptsRoot 'mc-board-dispatch.ps1'
$HeartbeatHelper = Join-Path $SharedScriptsRoot 'openclaw-heartbeat-session.ps1'
$TTL = 300
$AgentRole = if ($AgentId -eq $BoardId) { 'lead' } else { 'worker' }
$InvocationAgent = if ($AgentId -eq $BoardId) { "lead-$BoardId" } else { "mc-$AgentId" }

. $HeartbeatHelper

if ($ProcessQueue) {
    [void](Invoke-MissionControlHeartbeatQueueProcessor `
        -WorkspacePath $Wsp `
        -InvocationAgent $InvocationAgent `
        -TimeoutSec 120)
    exit 0
}

if (Test-MissionControlHeartbeatQueueProcessing -WorkspacePath $Wsp) {
    Write-Host "OK # queue processing"
    exit 0
}

# ── Cache miss or stale ──
try {
    & pwsh -NoProfile -File $Dispatch -AgentId $AgentId -BoardId $BoardId -AgentRole $AgentRole -WorkspacePath $Wsp | Out-File $State
}
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
    $dispatchStates = @()
    $activeTasks = @($j.tasks | Where-Object { $_ -and $_.id })
    if ($activeTasks.Count -eq 0) {
        $dispatchStates = @($j)
    }
    else {
        foreach ($task in $activeTasks) {
            $taskDispatchState = [ordered]@{
                act = $j.act
                reason = $j.reason
                agentRole = $j.agentRole
                boardId = $j.boardId
                agentId = $j.agentId
                summary = $j.summary
                tasks = @($task)
            }

            $dispatchStates += [pscustomobject]$taskDispatchState
        }
    }

    $queued = 0
    $skipped = 0
    foreach ($dispatchState in $dispatchStates) {
        if (Add-MissionControlHeartbeatQueueItem `
            -WorkspacePath $Wsp `
            -InvocationAgent $InvocationAgent `
            -DispatchState $dispatchState) {
            $queued++
        }
        else {
            $skipped++
        }
    }

    [void](Start-MissionControlHeartbeatQueueProcessor -WorkspacePath $Wsp -ScriptPath $PSCommandPath)
    Write-Host "OK # queued=$queued skipped=$skipped"
    exit 0
}
else {
    Write-Host "OK # act=false ($($j.reason))"
    exit 0
}
