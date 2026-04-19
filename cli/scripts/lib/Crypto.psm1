# AES encryption using PowerShell's ConvertTo-SecureString / ConvertFrom-SecureString (Method 1)

function Protect-MconData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlainText,
        [Parameter(Mandatory)][string]$KeyPath = '~/.mcon-secret.key'
    )

    $resolvedKey = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KeyPath)
    if (-not (Test-Path -LiteralPath $resolvedKey)) {
        throw "Key file not found at $resolvedKey. Generate it with: pwsh -Command `"New-MconKey -KeyPath '$resolvedKey'`""
    }

    $key = Get-Content -Path $resolvedKey -AsByteStream
    $encryptedContent = $PlainText | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString -Key $key
    return $encryptedContent
}

function Unprotect-MconData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EncryptedContent,
        [Parameter(Mandatory)][string]$KeyPath = '~/.mcon-secret.key'
    )

    $resolvedKey = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KeyPath)
    if (-not (Test-Path -LiteralPath $resolvedKey)) {
        throw "Key file not found at $resolvedKey."
    }

    $key = Get-Content -Path $resolvedKey -AsByteStream
    $secureString = ConvertTo-SecureString -String $EncryptedContent -Key $key
    $bstrPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrPtr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrPtr)
    return $plainText
}

function Protect-MconFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlainTextPath,
        [Parameter(Mandatory)][string]$CipherPath,
        [string]$KeyPath = '~/.mcon-secret.key'
    )
    $resolvedPlain = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PlainTextPath)
    $resolvedCipher = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CipherPath)
    $content = Get-Content -LiteralPath $resolvedPlain -Raw
    $enc = Protect-MconData -PlainText $content -KeyPath $KeyPath
    $enc | Set-Content -LiteralPath $resolvedCipher -Encoding UTF8
}

function Unprotect-MconFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CipherPath,
        [Parameter(Mandatory)][string]$PlainTextPath,
        [string]$KeyPath = '~/.mcon-secret.key'
    )
    $resolvedCipher = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CipherPath)
    $resolvedPlain = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PlainTextPath)
    $enc = Get-Content -LiteralPath $resolvedCipher -Raw
    $plain = Unprotect-MconData -EncryptedContent $enc -KeyPath $KeyPath
    $plain | Set-Content -LiteralPath $resolvedPlain -Encoding UTF8
}

function New-MconKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KeyPath
    )
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KeyPath)
    $dir = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $key = New-Object Byte[] 32
    [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($key) | Out-Null
    [System.IO.File]::WriteAllBytes($resolvedPath, $key)
}

Export-ModuleMember -Function Protect-MconData, Unprotect-MconData, Protect-MconFile, Unprotect-MconFile, New-MconKey
