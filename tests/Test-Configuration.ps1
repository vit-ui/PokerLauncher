$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Configuration.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$config = Convert-LauncherConfiguration $null
Assert ($config.Helpers.Count -eq 0 -and $config.LoginMode -eq 'Manual') 'Fresh defaults'
$legacy = [pscustomobject]@{ SchemaVersion = 1; PokerStarsUsername = 'alice'; Applications = [pscustomobject]@{ PokerStarsUpdater = 'C:\PokerStars\PokerStarsUpdate.exe'; XeesterUpdater = 'C:\Xeester\update.exe'; StarsCaption = 'C:\Caption\caption.exe' } }
$config = Convert-LauncherConfiguration $legacy
Assert ($config.Helpers.Count -eq 2 -and $config.LoginMode -eq 'PokerStars' -and $config.PokerStarsUsername -eq 'alice') 'Legacy conversion'
Assert ($config.Helpers[0].ApplicationPath -eq 'C:\Xeester\jre\bin\xeester.exe') 'Updater conversion'
$fixtureRoot = Join-Path $env:TEMP ('PokerLauncher-config-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
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
    $fake = Join-Path $fixtureRoot 'PokerStars.exe'
    Copy-Item -LiteralPath "$env:SystemRoot\System32\cmd.exe" -Destination $fake
    $failed = $false
    try { Assert-ProgramFiles (Resolve-ProgramEntry (New-ProgramEntry 'PokerStars' $fake)) -PokerStars } catch { $failed = $true }
    Assert $failed 'Renamed unrelated executable must be rejected'
    Remove-Item -LiteralPath $fake
    Add-Type -OutputAssembly $fake -OutputType WindowsApplication -TypeDefinition @'
using System;
[assembly: System.Reflection.AssemblyProduct("PokerStars Test Fixture")]
public static class ConfigurationFixture { public static void Main() {} }
'@
    $config = Convert-LauncherConfiguration $null
    $config.PokerClient = New-ProgramEntry 'PokerStars' $fake
    Assert-LauncherConfiguration $config
    $config.Helpers = @((New-ProgramEntry 'Duplicate' $fake))
    $failed = $false
    try { Assert-LauncherConfiguration $config } catch { $failed = $_.Exception.Message -like '*Duplicate application*' }
    Assert $failed 'Duplicate application paths must be rejected'
    $config.Helpers = @()
    for ($i = 0; $i -lt 500; $i++) { $config.Helpers += New-ProgramEntry ('Helper ' + $i) (Join-Path $fixtureRoot ($i.ToString() + '.exe')) }
    Assert-LauncherConfiguration $config
    $config.PokerStarsUsername = 'user-' + [char]0x00e9
    Write-LauncherConfiguration $config $path
    $loaded = Read-LauncherConfiguration $path
    Assert ($loaded.Helpers.Count -eq 500 -and $loaded.PokerStarsUsername -ceq $config.PokerStarsUsername) 'Many helpers and UTF-8 round trip'
    [IO.File]::WriteAllText($path, '{invalid')
    $failed = $false
    try { Read-LauncherConfiguration $path } catch { $failed = $true }
    Assert $failed 'Malformed JSON must be rejected'
    $failed = $false
    try { Convert-LauncherConfiguration ([pscustomobject]@{ SchemaVersion = 99 }) } catch { $failed = $true }
    Assert $failed 'Unknown schema must be rejected'
} finally {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'Configuration tests passed.'
