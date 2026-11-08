$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\Configuration.ps1')
$testRoot = Join-Path $env:TEMP ('PokerLauncher-migration-' + [guid]::NewGuid())
$previous = $env:APPDATA
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    $env:APPDATA = $testRoot
    $legacy = Join-Path $testRoot 'PokerStarsLauncher'
    New-Item -ItemType Directory -Path $legacy -Force | Out-Null
    $config = [pscustomobject]@{ SchemaVersion = 1; PokerStarsUsername = 'test'; Applications = [pscustomobject]@{ PokerStarsUpdater = 'C:\PokerStars\PokerStarsUpdate.exe'; XeesterUpdater = 'C:\Xeester\update.exe'; StarsCaption = 'C:\Caption\caption.exe' } }
    Write-LauncherConfiguration $config (Join-Path $legacy 'config.json')
    $secure = ConvertTo-SecureString 'fixture-only-password' -AsPlainText -Force
    try { [IO.File]::WriteAllText((Join-Path $legacy 'password.dpapi'), (ConvertFrom-SecureString $secure)) } finally { $secure.Dispose() }
    $script = Join-Path $root 'scripts\migrate.ps1'
    & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script
    if ($LASTEXITCODE -ne 0) { throw 'Migration failed.' }
    $newRoot = Join-Path $testRoot 'PokerLauncher'
    $newPath = Join-Path $newRoot 'config.json'
    $result = Read-LauncherConfiguration $newPath
    if ($result.SchemaVersion -ne 2 -or $result.Helpers.Count -ne 2 -or $result.LoginMode -ne 'PokerStars') { throw 'Migration lost settings.' }
    if ([IO.File]::ReadAllText((Join-Path $legacy 'password.dpapi')) -cne [IO.File]::ReadAllText((Join-Path $newRoot 'password.dpapi'))) { throw 'Credentials changed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $newRoot 'legacy-backup\config.json'))) { throw 'Missing backup.' }
    $result.PokerStarsUsername = 'keep-new-settings'; Write-LauncherConfiguration $result $newPath
    & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script
    if ($LASTEXITCODE -ne 0 -or (Read-LauncherConfiguration $newPath).PokerStarsUsername -ne 'keep-new-settings') { throw 'Repeat migration overwrote settings.' }
    # An invalid password must fail without publishing a new configuration.
    Remove-Item -LiteralPath $newRoot -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $legacy 'password.dpapi'), 'invalid')
    $ErrorActionPreference = 'Continue'
    & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $newPath)) { throw 'Invalid credentials were migrated.' }
    Write-Host 'Migration tests passed.'
} finally { $env:APPDATA = $previous; Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
