$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this validation with Windows PowerShell 5.1 (the launcher runtime).'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptDirectory = Join-Path $repoRoot 'scripts'
$scriptFiles = @(Get-ChildItem -LiteralPath $scriptDirectory -Filter '*.ps1' -File -Recurse)
if ($scriptFiles.Count -lt 5) {
    throw 'Expected setup, registration, launch, login, and uninstall PowerShell components under scripts/.'
}

$parseFailures = @()
$csharpTypesCompiled = 0
foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in $parseErrors) {
        $parseFailures += ('{0}:{1}:{2}: {3}' -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
    }

    # In Windows PowerShell 5.1, Split-Path -LiteralPath and -Parent belong
    # to incompatible parameter sets. Detect this at validation time rather
    # than letting the affected application fail only during first launch.
    $splitPathCommands = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Split-Path'
    }, $true)
    foreach ($command in $splitPathCommands) {
        $parameterNames = @($command.CommandElements |
            Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
            ForEach-Object { $_.ParameterName })
        if ($parameterNames -contains 'LiteralPath' -and $parameterNames -contains 'Parent') {
            $parseFailures += ('{0}:{1}: Split-Path cannot combine -LiteralPath with -Parent in Windows PowerShell 5.1.' -f $file.FullName, $command.Extent.StartLineNumber)
        }
    }

    # The launch/login scripts embed C# native API declarations in here-strings.
    # The uninstall script also carries PowerShell source as a here-string; only
    # compile blocks that are recognizably C# declarations.
    $hereStrings = @($tokens | Where-Object {
        $_.Kind -eq [System.Management.Automation.Language.TokenKind]::HereStringLiteral
    })
    foreach ($token in $hereStrings) {
        $match = [regex]::Match($token.Text, "(?s)\A@'\r?\n(?<source>.*?)\r?\n'@\z")
        if (-not $match.Success) { continue }
        $source = $match.Groups['source'].Value
        if ($source -notmatch '(?m)^using System;') { continue }
        Add-Type -TypeDefinition $source -ErrorAction Stop
        $csharpTypesCompiled++
    }
}

if ($parseFailures.Count -gt 0) {
    throw ("PowerShell parser errors:`r`n" + ($parseFailures -join "`r`n"))
}
if ($csharpTypesCompiled -lt 2) {
    throw "Expected to compile the launcher and PokerStars native C# declarations; compiled $csharpTypesCompiled."
}

$requiredFiles = @(
    'go.mod',
    'main.go',
    'app_windows.go',
    'scripts/setup.ps1',
    'scripts/register.ps1',
    'scripts/launch.ps1',
    'scripts/PokerStarsLogin.ps1',
    'scripts/uninstall.ps1',
    'assets/README.md',
    'version.txt',
    '.github/workflows/core-merge_safety.yml',
    '.github/workflows/core-release_pr.yml'
)
foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required project file is missing: $relativePath"
    }
}

$unexpectedUserLaunchers = @('setup.bat', 'launch.bat') | Where-Object {
    Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf
}
if ($unexpectedUserLaunchers.Count -gt 0) {
    throw 'Legacy batch entry points must not be shipped in the self-installing application repository.'
}

Write-Host ("Validated Windows PowerShell 5.1 syntax and {0} embedded C# declarations across {1} scripts, then checked required project files." -f $csharpTypesCompiled, $scriptFiles.Count)
