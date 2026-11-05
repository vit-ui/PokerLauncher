$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this validation with Windows PowerShell 5.1 (the launcher runtime). '
}
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

    # These scripts embed native Windows API declarations in C# here-strings.
    # Compile each embedded declaration so CI validates more than PowerShell
    # syntax (including the launcher Job Object and PokerStars native controls).
    $hereStrings = @($tokens | Where-Object {
        $_.Kind -eq [System.Management.Automation.Language.TokenKind]::HereStringLiteral
    })
    foreach ($token in $hereStrings) {
        $match = [regex]::Match($token.Text, "(?s)\A@'\r?\n(?<source>.*?)\r?\n'@\z")
        if (-not $match.Success) {
            throw ("Could not extract C# here-string in {0}:{1}." -f $file.FullName, $token.Extent.StartLineNumber)
        }
        Add-Type -TypeDefinition $match.Groups['source'].Value -ErrorAction Stop
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

Write-Host ("Validated Windows PowerShell 5.1 syntax and embedded C# in {0} script(s), then checked required files." -f $scriptFiles.Count)
