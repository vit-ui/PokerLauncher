$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$profile = Join-Path $env:TEMP ('PokerLauncher-settings-' + [guid]::NewGuid())
$previous = $env:APPDATA
$testState = @{ Failed = $false }
try {
    $env:APPDATA = $profile
    $source = Get-Content -LiteralPath (Join-Path $root 'scripts\setup.ps1') -Raw
    $source = $source.Replace(". (Join-Path `$PSScriptRoot 'Configuration.ps1')", ". '" + (Join-Path $root 'scripts\Configuration.ps1') + "'")
    # Drive real form controls without opening a modal window or starting apps.
    $exercise = @'
    if ($helpers.Count -ne 0 -or $login.Checked) { throw 'Fresh settings must be blank and manual.' }
    $helpers.Add((New-ProgramEntry 'First' 'C:\first.exe'))
    $helpers.Add((New-ProgramEntry 'Second' 'C:\second.exe'))
    & $refresh
    $list.SelectedIndex = 1
    $up.PerformClick()
    if ($helpers[0].Name -ne 'Second') { throw 'Move up failed.' }
    $down.PerformClick()
    if ($helpers[1].Name -ne 'Second') { throw 'Move down failed.' }
    $remove.PerformClick()
    if ($helpers.Count -ne 1 -or $helpers[0].Name -ne 'First') { throw 'Remove failed.' }
    $login.Checked = $true
    if (-not $credentials.Visible -and $form.Visible) { throw 'Credential visibility failed.' }
    if (-not $password.UseSystemPasswordChar) { throw 'Password must be masked.' }
    Write-Host 'Settings control tests passed.'
'@
    # PerformClick requires a visible parent; use Shown then close on completion.
    $source = $source.Replace('[void]$form.ShowDialog()', '$form.Add_Shown({ try { ' + $exercise + ' } catch { [Console]::Error.WriteLine($_.ToString()); $testState.Failed = $true } finally { $form.Close() } }.GetNewClosure()); [void]$form.ShowDialog(); if ($testState.Failed) { throw ''Settings test failed.'' }')
    & ([scriptblock]::Create($source))
} finally {
    $env:APPDATA = $previous
    Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
}
