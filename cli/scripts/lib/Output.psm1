function Write-MconResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Data,
        [int]$Depth = 12
    )

    $Data | ConvertTo-Json -Depth $Depth -Compress
}

function Write-MconError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Code = 'error'
    )

    [ordered]@{
        ok    = $false
        error = $Message
        code  = $Code
    } | ConvertTo-Json -Depth 4 -Compress

    [System.Environment]::Exit(1)
}

function Write-MconFatal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    [Console]::Error.WriteLine($Message)
    [System.Environment]::Exit(1)
}

Export-ModuleMember -Function Write-MconResult, Write-MconError, Write-MconFatal
