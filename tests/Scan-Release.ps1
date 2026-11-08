param(
    [Parameter(Mandatory = $true)][string]$Path,
    [uri]$SourceUrl = 'https://github.com/vit-ui/PokerStarsLauncher/releases/latest/download/PokerLauncher.exe'
)

$ErrorActionPreference = 'Stop'
$artifact = (Resolve-Path -LiteralPath $Path).ProviderPath
if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
    throw "Release executable is missing: $artifact"
}

$status = Get-MpComputerStatus
if (-not $status.AMServiceEnabled -or -not $status.AntivirusEnabled) {
    throw 'Microsoft Defender Antivirus must be available and enabled to validate a release.'
}

$platformRoot = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
$scanner = $null
if (Test-Path -LiteralPath $platformRoot -PathType Container) {
    $scanner = Get-ChildItem -LiteralPath $platformRoot -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+){3}(-\d+)?$' } |
        Sort-Object { [version](($_.Name -split '-')[0]) } -Descending |
        ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if (-not $scanner) { $scanner = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe' }
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw 'Microsoft Defender command-line scanner was not found.'
}

& $scanner -SignatureUpdate
if ($LASTEXITCODE -ne 0) {
    throw "Defender security intelligence update failed with exit code $LASTEXITCODE. Release upload is blocked."
}

$before = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
# DisableRemediation keeps this a scan: it does not disable protection. It
# also ignores exclusions, and findings are reported in the command output.
& $scanner -Scan -ScanType 3 -File $artifact -DisableRemediation
if ($LASTEXITCODE -ne 0) {
    throw "Defender found a threat or could not complete the scan (exit code $LASTEXITCODE). Release upload is blocked."
}
if (-not (Test-Path -LiteralPath $artifact -PathType Leaf) -or
    (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash -ne $before) {
    throw 'The executable was removed or changed during scanning. Release upload is blocked.'
}
Write-Host "Defender release scan passed. SHA256: $before"
& (Join-Path $PSScriptRoot 'Check-Download.ps1') -Path $artifact -ExpectedSha256 $before -SourceUrl $SourceUrl
