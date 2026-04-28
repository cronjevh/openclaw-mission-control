$script:RoleMap = @{
    'workspace-lead-'    = 'lead'
    'workspace-gateway-' = 'gateway'
    'workspace-mc-'      = 'worker'
}

$script:Permissions = @{
    'task.list'            = @('lead', 'gateway', 'worker', 'verifier')
    'task.move'            = @('gateway')
    'task.movetoboard'     = @('gateway', 'lead')
    'task.update'          = @('lead', 'gateway')
    'admin.gettokens'      = @('gateway')
    'admin.decrypt-keybag' = @('gateway')
    'admin.templatedist'   = @('gateway')
    'admin.cron'           = @('gateway')
    'workflow.assign'      = @('lead')
    'workflow.dispatch'      = @('lead', 'worker', 'verifier')
    'workflow.dispatchboard'  = @('gateway')
    'workflow.blocker'        = @('worker', 'verifier')
    'workflow.escalate'    = @('lead')
    'workflow.gateway-reply' = @('gateway')
    'workflow.submitreview' = @('worker', 'verifier')
    'verify.run'           = @('verifier')
    'verify.fail'          = @('verifier')
}

function Resolve-MconRole {
    param([Parameter(Mandatory)][string]$Wsp)

    foreach ($prefix in @('workspace-lead-', 'workspace-gateway-', 'workspace-mc-')) {
        if ($Wsp.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $script:RoleMap[$prefix]
        }
    }

    throw "Cannot determine role from MCON_WSP='$Wsp'. Expected prefix: workspace-lead-*, workspace-gateway-*, or workspace-mc-*."
}

function Resolve-MconExecutionRole {
    param(
        [Parameter(Mandatory)][string]$Wsp,
        [string]$WorkspacePath
    )

    $baseRole = Resolve-MconRole -Wsp $Wsp
    if ($baseRole -ne 'worker') {
        return $baseRole
    }

    $resolvedWorkspacePath = $WorkspacePath
    if (-not $resolvedWorkspacePath) {
        $resolvedWorkspacePath = Join-Path '/home/cronjev/.openclaw' $Wsp
    }

    $agentsPath = Join-Path $resolvedWorkspacePath 'AGENTS.md'
    if (Test-Path -LiteralPath $agentsPath) {
        $agentsContent = Get-Content -LiteralPath $agentsPath -Raw
        if ($agentsContent -match '(?im)^\s*this workspace is for verifier agent:') {
            return 'verifier'
        }
    }

    return $baseRole
}

function Test-MconPermission {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Role
    )

    if (-not $script:Permissions.ContainsKey($Action)) {
        return $true
    }

    $allowed = $script:Permissions[$Action]
    return $allowed -contains $Role
}

function Get-MconDeniedMessage {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Role
    )

    $allowed = $script:Permissions[$Action] -join ', '
    return "Permission denied: role '$Role' cannot perform '$Action'. Allowed roles: $allowed."
}

function Get-MconPermissions {
    return $script:Permissions.Clone()
}

Export-ModuleMember -Function Resolve-MconRole, Resolve-MconExecutionRole, Test-MconPermission, Get-MconDeniedMessage, Get-MconPermissions
