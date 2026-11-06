$ErrorActionPreference = 'Stop'

$appDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$launcherPath = Join-Path $appDirectory 'PokerStarsLauncher.exe'
$versionPath = Join-Path $appDirectory 'version.txt'
$iconPath = Join-Path $appDirectory 'assets\PokerStarsLauncher.ico'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PokerStarsLauncher'

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
        [string]$Description = 'Launch PokerStars, Xeester, and StarsCaption, then sign in to PokerStars.'
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
New-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'PokerStarsLauncher' -PropertyType String -Force | Out-Null
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
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'PokerStarsLauncher'
New-Item -ItemType Directory -Path $startMenu -Force | Out-Null
New-ApplicationShortcut -Path (Join-Path $desktop 'PokerStars Launcher.lnk')
New-ApplicationShortcut -Path (Join-Path $startMenu 'PokerStars Launcher.lnk')
New-ApplicationShortcut -Path (Join-Path $startMenu 'Configure PokerStarsLauncher.lnk') -Arguments '--setup' -Description 'Change PokerStarsLauncher settings.'
