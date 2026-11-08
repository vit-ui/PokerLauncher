$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Configuration.ps1')
$legacy = Join-Path $env:APPDATA 'PokerStarsLauncher'
$destination = Join-Path $env:APPDATA 'PokerLauncher'
$legacyConfig = Join-Path $legacy 'config.json'
$targetConfig = Join-Path $destination 'config.json'
if (Test-Path -LiteralPath $targetConfig -PathType Leaf) { exit 0 }
if (-not (Test-Path -LiteralPath $legacyConfig -PathType Leaf)) { exit 0 }
$config = Read-LauncherConfiguration $legacyConfig
# Check the structure without requiring applications to still be installed.
if ($config.Integration -ne 'PokerStars' -or $null -eq $config.PokerClient) { throw 'Invalid legacy configuration.' }
foreach ($entry in (@($config.PokerClient) + @($config.Helpers))) { $null = Resolve-ProgramEntry $entry }
$credential = Join-Path $legacy 'password.dpapi'
if ($config.LoginMode -eq 'PokerStars') {
    $secure = $null
    try {
        $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($credential).Trim())
        if ($secure.Length -eq 0) { throw 'Empty legacy password.' }
    } finally { if ($null -ne $secure) { $secure.Dispose() } }
}
# Stage all data, including an untouched legacy backup, before publishing config.
# The config rename is the completion marker; failed attempts can be retried.
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$stage = Join-Path $destination ('migration-' + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item -LiteralPath $legacy -Destination (Join-Path $stage 'legacy-backup') -Recurse
    if (Test-Path -LiteralPath $credential) {
        Copy-Item -LiteralPath $credential -Destination (Join-Path $stage 'password.dpapi')
        if ([IO.File]::ReadAllText($credential) -cne [IO.File]::ReadAllText((Join-Path $stage 'password.dpapi'))) { throw 'Credential copy verification failed.' }
        Copy-Item -LiteralPath (Join-Path $stage 'password.dpapi') -Destination (Join-Path $destination 'password.dpapi') -Force
    }
    if (-not (Test-Path -LiteralPath (Join-Path $destination 'legacy-backup'))) {
        Move-Item -LiteralPath (Join-Path $stage 'legacy-backup') -Destination (Join-Path $destination 'legacy-backup')
    }
    Write-LauncherConfiguration $config (Join-Path $stage 'config.json')
    $verified = Read-LauncherConfiguration (Join-Path $stage 'config.json')
    if ($verified.SchemaVersion -ne 2 -or @($verified.Helpers).Count -ne @($config.Helpers).Count) { throw 'Migration verification failed.' }
    # Move without overwrite: concurrent or existing new configurations win.
    [IO.File]::Move((Join-Path $stage 'config.json'), $targetConfig)
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
