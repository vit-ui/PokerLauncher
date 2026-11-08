$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Configuration.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$config = Convert-LauncherConfiguration $null
Assert ($config.Helpers.Count -eq 0 -and $config.LoginMode -eq 'Manual') 'Fresh defaults'
$legacy = [pscustomobject]@{ SchemaVersion = 1; PokerStarsUsername = 'alice'; Applications = [pscustomobject]@{ PokerStarsUpdater = 'C:\PokerStars\PokerStarsUpdate.exe'; XeesterUpdater = 'C:\Xeester\update.exe'; StarsCaption = 'C:\Caption\caption.exe' } }
$config = Convert-LauncherConfiguration $legacy
Assert ($config.Helpers.Count -eq 2 -and $config.LoginMode -eq 'PokerStars' -and $config.PokerStarsUsername -eq 'alice') 'Legacy conversion'
Assert ($config.Helpers[0].ApplicationPath -eq 'C:\Xeester\jre\bin\xeester.exe') 'Updater conversion'
$path = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.json')
try {
    Write-LauncherConfiguration $config $path
    Write-LauncherConfiguration $config $path
    $loaded = Read-LauncherConfiguration $path
    Assert ($loaded.SchemaVersion -eq 2 -and $loaded.Helpers.Count -eq 2) 'Atomic round trip'
    Assert-WindowsExecutable "$env:SystemRoot\System32\cmd.exe"
    $failed = $false
    try { Assert-ProgramFiles (Resolve-ProgramEntry (New-ProgramEntry 'Fake PokerStars' "$env:SystemRoot\System32\cmd.exe")) -PokerStars } catch { $failed = $true }
    Assert $failed 'Unrelated client must be rejected'
    $failed = $false
    try { Convert-LauncherConfiguration ([pscustomobject]@{ SchemaVersion = 99 }) } catch { $failed = $true }
    Assert $failed 'Unknown schema must be rejected'
} finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
Write-Host 'Configuration tests passed.'
