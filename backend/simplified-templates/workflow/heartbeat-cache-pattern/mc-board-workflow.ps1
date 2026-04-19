#!/usr/bin/env pwsh
<# Cached board-dispatch: check cache first; if fresh and act unchanged, skip gate entirely. #>
param(
    [switch]$ProcessQueue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AgentId = '{{id}}'
$BoardId = '{{board_id}}'
$Wsp = '{{workspace_path}}'
$State = Join-Path $Wsp '.openclaw/workflows/.dispatch-state-latest.json'
$SharedScriptsRoot = '/home/cronjev/mission-control-tfsmrt/scripts'
$Dispatch = Join-Path $SharedScriptsRoot 'mc-board-dispatch.ps1'
$HeartbeatHelper = Join-Path $SharedScriptsRoot 'openclaw-heartbeat-session.ps1'
$QueueTimeoutSec = 600
$AgentRole = '{{agent_render_role}}'
$InvocationAgent = if ($AgentRole -eq 'lead') { "lead-$BoardId" } else { "mc-$AgentId" }

. $HeartbeatHelper

exit (Invoke-MissionControlHeartbeatWorkflow `
    -WorkspacePath $Wsp `
    -AgentId $AgentId `
    -BoardId $BoardId `
    -AgentRole $AgentRole `
    -InvocationAgent $InvocationAgent `
    -DispatchScriptPath $Dispatch `
    -StatePath $State `
    -WorkflowScriptPath $PSCommandPath `
    -QueueTimeoutSec $QueueTimeoutSec `
    -ProcessQueue:$ProcessQueue)
