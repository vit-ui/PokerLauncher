param([int]$ParentProcessId)
$ErrorActionPreference = 'Stop'
# Only retire a known old installation after the new registration is published.
$expected = Join-Path $env:LOCALAPPDATA 'Programs\PokerStarsLauncher'
$registration = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PokerLauncher'
if (-not (Test-Path -LiteralPath $registration)) { exit 0 }
if ($ParentProcessId -gt 0) {
    try { $parent = Get-Process -Id $ParentProcessId -ErrorAction Stop; $parent.WaitForExit() } catch { }
}
Remove-Item -LiteralPath $expected -Recurse -Force -ErrorAction SilentlyContinue
