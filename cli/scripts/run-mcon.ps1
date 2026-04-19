#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Wrapper to run mcon.ps1 with explicit env vars.
.DESCRIPTION
    Accepts -BaseURL, -Token, -BoardID, -WSP as parameters, sets them as env vars,
    then runs mcon.ps1 with the provided -Args array.
#>

param(
    [string]$BaseURL,
    [string]$Token,
    [string]$BoardID,
    [string]$WSP,
    [Parameter(Mandatory)][string[]]$Args
)

$env:MCON_BASE_URL = if ($BaseURL) { $BaseURL } else { $env:MCON_BASE_URL }
$env:MCON_AUTH_TOKEN = if ($Token) { $Token } else { $env:MCON_AUTH_TOKEN }
$env:MCON_BOARD_ID = if ($BoardID) { $BoardID } else { $env:MCON_BOARD_ID }
$env:MCON_WSP = if ($WSP) { $WSP } else { $env:MCON_WSP }

& "$PSScriptRoot/mcon.ps1" @Args
