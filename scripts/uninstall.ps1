$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$appDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$appDataRoot = Join-Path $env:APPDATA 'PokerLauncher'
$localDataRoot = Join-Path $env:LOCALAPPDATA 'PokerLauncher'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'PokerLauncher.lnk'
$startMenuFolder = Join-Path ([Environment]::GetFolderPath('Programs')) 'PokerLauncher'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PokerLauncher'

$choice = [System.Windows.Forms.MessageBox]::Show(
    "Remove PokerLauncher from this Windows account?`r`n`r`nChoose Yes to also remove the saved username, executable paths, and encrypted password. Choose No to keep those settings in case you reinstall later.",
    'Uninstall PokerLauncher',
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { exit 0 }
$removeUserData = $choice -eq [System.Windows.Forms.DialogResult]::Yes

Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuFolder -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue

$cleanupPath = Join-Path $env:TEMP ('PokerLauncher-cleanup-' + [guid]::NewGuid().ToString('N') + '.ps1')
$cleanupScript = @'
param(
    [int]$ParentProcessId,
    [string]$ApplicationDirectory,
    [string]$AppDataDirectory,
    [string]$LocalDataDirectory,
    [ValidateSet('True', 'False')][string]$RemoveUserData,
    [string]$SelfPath
)

try {
    $parent = Get-Process -Id $ParentProcessId -ErrorAction Stop
    $parent.WaitForExit()
}
catch { }

Start-Sleep -Milliseconds 300
Remove-Item -LiteralPath $ApplicationDirectory -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveUserData -eq 'True') {
    Remove-Item -LiteralPath $AppDataDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LocalDataDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $SelfPath -Force -ErrorAction SilentlyContinue
'@
[System.IO.File]::WriteAllText($cleanupPath, $cleanupScript, ([System.Text.UTF8Encoding]::new($false)))

$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', ('"{0}"' -f $cleanupPath),
    '-ParentProcessId', [int]$env:POKERSTARSL_PARENT_PID,
    '-ApplicationDirectory', ('"{0}"' -f $appDirectory),
    '-AppDataDirectory', ('"{0}"' -f $appDataRoot),
    '-LocalDataDirectory', ('"{0}"' -f $localDataRoot),
    '-RemoveUserData', ([string]$removeUserData),
    '-SelfPath', ('"{0}"' -f $cleanupPath)
) -join ' '
Start-Process -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden

[System.Windows.Forms.MessageBox]::Show(
    'PokerLauncher has been unregistered. Its application files will be removed after this window closes.',
    'Uninstall PokerLauncher',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null
exit 0
