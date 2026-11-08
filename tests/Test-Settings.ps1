$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$profile = Join-Path $env:TEMP ('PokerLauncher-settings-' + [guid]::NewGuid())
$previous = $env:APPDATA
try {
    foreach ($case in @('fresh', 'missing-password', 'invalid-password', 'malformed-legacy')) {
    $env:APPDATA = Join-Path $profile $case
    if ($case -ne 'fresh') {
        $legacy = Join-Path $env:APPDATA 'PokerStarsLauncher'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        $legacyJson = '{"SchemaVersion":1,"PokerStarsUsername":"recover-me","Applications":{"PokerStarsUpdater":"C:\\PokerStars\\PokerStarsUpdate.exe","XeesterUpdater":"C:\\Xeester\\update.exe","StarsCaption":"C:\\Caption\\caption.exe"}}'
        if ($case -eq 'malformed-legacy') { $legacyJson = '{invalid' }
        [IO.File]::WriteAllText((Join-Path $legacy 'config.json'), $legacyJson)
        if ($case -eq 'invalid-password') { [IO.File]::WriteAllText((Join-Path $legacy 'password.dpapi'), 'invalid') }
    }
    $source = Get-Content -LiteralPath (Join-Path $root 'scripts\setup.ps1') -Raw
    $source = $source.Replace(". (Join-Path `$PSScriptRoot 'Configuration.ps1')", ". '" + (Join-Path $root 'scripts\Configuration.ps1') + "'")
    # Drive real form controls without opening a modal window or starting apps.
    $exercise = @'
    if ($case -in @('fresh', 'malformed-legacy')) {
        if ($helpers.Count -ne 0 -or $login.Checked) { throw 'Fresh settings must be blank and manual.' }
    } else {
        if ($helpers.Count -ne 2 -or -not $login.Checked -or $username.Text -ne 'recover-me' -or $state.Client.Path -ne 'C:\PokerStars\PokerStarsUpdate.exe') { throw 'Settings recovery lost legacy program settings.' }
        $login.Checked = $false
        if ($credentials.Visible) { throw 'Manual login recovery is not accessible.' }
        $helpers.Clear()
    }
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
    # Define test context in the evaluated script so event closures capture it
    # even when this test is invoked from the full validation entry point.
    $source = ('$case = ''{0}''; $testState = @{{ Failed = $false }}' -f $case) + "`r`n" + $source
    & ([scriptblock]::Create($source))
    if (Test-Path -LiteralPath (Join-Path $env:APPDATA 'PokerLauncher\config.json')) { throw 'Cancelling Settings published a configuration.' }
    if ($case -ne 'fresh') {
        if ([IO.File]::ReadAllText((Join-Path $legacy 'config.json')) -cne $legacyJson) { throw 'Settings recovery modified legacy configuration.' }
        if ($case -eq 'invalid-password' -and [IO.File]::ReadAllText((Join-Path $legacy 'password.dpapi')) -cne 'invalid') { throw 'Settings recovery modified the legacy password.' }
    }
    }
} finally {
    $env:APPDATA = $previous
    Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
}
