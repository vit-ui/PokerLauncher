$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -File -Recurse)

if ($scriptFiles.Count -eq 0) {
    throw 'No PowerShell scripts were found under scripts/.'
}

$parseFailures = @()
foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            $parseFailures += ('{0}:{1}:{2}: {3}' -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
        }
    }
}

if ($parseFailures.Count -gt 0) {
    throw ("PowerShell parser errors:`n" + ($parseFailures -join "`n"))
}

$requiredFiles = @(
    'setup.bat',
    'launch.bat',
    'scripts/setup.ps1',
    'scripts/launch.ps1',
    'scripts/PokerStarsLogin.ps1',
    '.github/workflows/core-merge_safety.yml',
    '.github/workflows/core-release_pr.yml'
)
foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required project file is missing: $relativePath"
    }
}

Write-Host ("Validated PowerShell syntax in {0} script(s) and checked required files." -f $scriptFiles.Count)
