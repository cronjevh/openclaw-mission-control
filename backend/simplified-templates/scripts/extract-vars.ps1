param(
    [string]$TemplateRoot = (Join-Path $PSScriptRoot "..\..\templates")
)

$targets = @(
    @{
        Pattern = 'BOARD_WORKER_*.md.j2'
    },
    @{
        Pattern = 'BOARD_LEAD_*.md.j2'
    }
)

$allVariables = foreach ($target in $targets) {
    $templateFiles = Get-ChildItem -Path $TemplateRoot -Filter $target.Pattern -File | Sort-Object Name

    foreach ($file in $templateFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $matches = [regex]::Matches($content, '\{\{\s*([^{}]+?)\s*\}\}|\$\{([^}]+?)\}')

        foreach ($match in $matches) {
            $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            $value.Trim()
        }
    }
}

$uniqueVariables = $allVariables | Where-Object { $_ } | Sort-Object -Unique

$lines = foreach ($variable in $uniqueVariables) {
    "$variable="
}

Set-Content -LiteralPath (Join-Path $PSScriptRoot "..\.env") -Value $lines -NoNewline:$false
