$ErrorActionPreference = 'Stop'

$appDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$launcherPath = Join-Path $appDirectory 'PokerLauncher.exe'
$versionPath = Join-Path $appDirectory 'version.txt'
$iconPath = Join-Path $appDirectory 'assets\PokerLauncher.ico'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PokerLauncher'

function Test-ICOFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 6) { throw "The application icon is invalid: $Path" }
        $header = New-Object byte[] 4
        [void]$stream.Read($header, 0, 4)
        if ($header[0] -ne 0 -or $header[1] -ne 0 -or $header[2] -ne 1 -or $header[3] -ne 0) {
            throw "The application icon is not a valid ICO file: $Path"
        }
    }
    finally { $stream.Dispose() }
    return $true
}

function New-ApplicationShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Arguments = '--launch',
        [string]$Description = 'Launch your poker client and configured helpers.'
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $launcherPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $appDirectory
    $shortcut.Description = $Description
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
        [void](Test-ICOFile -Path $iconPath)
        $shortcut.IconLocation = "$iconPath,0"
    }
    else {
        $shortcut.IconLocation = "$launcherPath,0"
    }
    $shortcut.Save()
}

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "Installed application executable is missing: $launcherPath"
}
if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw "Installed version file is missing: $versionPath"
}

New-Item -Path $uninstallKey -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'PokerLauncher' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value (Get-Content -LiteralPath $versionPath -Raw).Trim() -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name Publisher -Value 'Vitor Cipriano' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $appDirectory -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name UninstallString -Value ('"{0}" --uninstall' -f $launcherPath) -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    $displayIcon = '"{0}",0' -f $iconPath
}
else {
    $displayIcon = '"{0}",0' -f $launcherPath
}
New-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value $displayIcon -PropertyType String -Force | Out-Null

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'PokerLauncher'
New-Item -ItemType Directory -Path $startMenu -Force | Out-Null
New-ApplicationShortcut -Path (Join-Path $desktop 'PokerLauncher.lnk')
New-ApplicationShortcut -Path (Join-Path $startMenu 'PokerLauncher.lnk')
New-ApplicationShortcut -Path (Join-Path $startMenu 'Configure PokerLauncher.lnk') -Arguments '--setup' -Description 'Change PokerLauncher settings.'

# Retire only application-owned legacy entries, after the new entries exist.
$legacyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PokerStarsLauncher'
$legacyData = Join-Path $env:APPDATA 'PokerStarsLauncher'
if (Test-Path -LiteralPath (Join-Path $env:APPDATA 'PokerLauncher\legacy-backup\config.json')) {
    Remove-Item -LiteralPath $legacyData -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $legacyKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $desktop 'PokerStars Launcher.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'PokerStarsLauncher') -Recurse -Force -ErrorAction SilentlyContinue
$legacyInstallation = Join-Path $env:LOCALAPPDATA 'Programs\PokerStarsLauncher'
if (Test-Path -LiteralPath (Join-Path $legacyInstallation 'PokerStarsLauncher.exe')) {
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cleanup = Join-Path $PSScriptRoot 'retire-legacy.ps1'
    Start-Process -FilePath $powerShell -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ParentProcessId {1}' -f $cleanup, [int]$env:POKERSTARSL_PARENT_PID) | Out-Null
}
