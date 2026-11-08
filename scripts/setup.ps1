$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'Configuration.ps1')
$appDataRoot = Join-Path $env:APPDATA 'PokerLauncher'
$configPath = Join-Path $appDataRoot 'config.json'
$passwordPath = Join-Path $appDataRoot 'password.dpapi'

function global:Add-Label {
    param($Parent, [string]$Text, [int]$Y)
    $label = [Windows.Forms.Label]::new(); $label.Text = $Text
    $label.SetBounds(18, $Y, 600, 20); $Parent.Controls.Add($label)
}
function global:Add-Text {
    param($Parent, [string]$Text, [int]$Y)
    $box = [Windows.Forms.TextBox]::new(); $box.Text = $Text
    $box.SetBounds(18, $Y, 500, 24); $Parent.Controls.Add($box); return $box
}
function global:Add-Button {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [scriptblock]$Action)
    $button = [Windows.Forms.Button]::new(); $button.Text = $Text
    $button.SetBounds($X, $Y, 90, 28); $button.Add_Click($Action)
    $Parent.Controls.Add($button); return $button
}
function global:Edit-Program {
    param($Owner, $Entry, [bool]$Client)
    $dialog = [Windows.Forms.Form]::new(); $dialog.Text = if ($Client) { 'PokerStars client' } else { 'Helper' }
    $dialog.ClientSize = [Drawing.Size]::new(640, 400); $dialog.StartPosition = 'CenterParent'
    $dialog.Font = [Drawing.Font]::new('Segoe UI', 9)
    Add-Label $dialog 'Display name' 12
    $name = Add-Text $dialog $Entry.Name 34
    Add-Label $dialog 'Launch executable (.exe)' 66
    $path = Add-Text $dialog $Entry.Path 88
    $browse = Add-Button $dialog 'Browse...' 530 86 ({
        $picker = [Windows.Forms.OpenFileDialog]::new(); $picker.Filter = 'Executables|*.exe'; $picker.CheckFileExists = $true
        try { if ($picker.ShowDialog($dialog) -eq 'OK') { $path.Text = $picker.FileName } } finally { $picker.Dispose() }
    }.GetNewClosure())
    $advanced = [Windows.Forms.CheckBox]::new(); $advanced.Text = 'Advanced settings'; $advanced.SetBounds(18, 125, 300, 24); $dialog.Controls.Add($advanced)
    $panel = [Windows.Forms.Panel]::new(); $panel.SetBounds(0, 153, 640, 200); $panel.Visible = $false; $dialog.Controls.Add($panel)
    Add-Label $panel 'Arguments (optional)' 0; $arguments = Add-Text $panel $Entry.Arguments 22
    Add-Label $panel 'Working directory (blank: launch executable folder)' 55; $directory = Add-Text $panel $Entry.WorkingDirectory 77
    Add-Label $panel 'Actual application EXE (blank: launch EXE; updater: select the app it starts)' 110
    $actual = Add-Text $panel $Entry.ApplicationPath 132
    $actualBrowse = Add-Button $panel 'Browse...' 530 130 ({
        $picker = [Windows.Forms.OpenFileDialog]::new(); $picker.Filter = 'Executables|*.exe'
        try { if ($picker.ShowDialog($dialog) -eq 'OK') { $actual.Text = $picker.FileName } } finally { $picker.Dispose() }
    }.GetNewClosure())
    $advanced.Add_CheckedChanged({ $panel.Visible = $advanced.Checked }.GetNewClosure())
    $advanced.Checked = -not [string]::IsNullOrWhiteSpace($Entry.ApplicationPath + $Entry.Arguments + $Entry.WorkingDirectory)
    $state = @{ Result = $null }
    $ok = Add-Button $dialog 'OK' 430 362 ({
        try {
            $candidate = [pscustomobject]@{ Name = $name.Text.Trim(); Path = $path.Text; Arguments = $arguments.Text; WorkingDirectory = $directory.Text; ApplicationPath = $actual.Text }
            if ($Client -and [string]::IsNullOrWhiteSpace($candidate.ApplicationPath) -and [IO.Path]::GetFileName($candidate.Path) -ieq 'PokerStarsUpdate.exe') {
                $candidate.ApplicationPath = Join-Path ([IO.Path]::GetDirectoryName($candidate.Path)) 'PokerStars.exe'
            }
            $resolved = Resolve-ProgramEntry $candidate
            Assert-ProgramFiles $resolved -PokerStars:$Client
            $state.Result = $candidate; $dialog.DialogResult = 'OK'; $dialog.Close()
        } catch { [void][Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Check program', 'OK', 'Warning') }
    }.GetNewClosure())
    $cancel = Add-Button $dialog 'Cancel' 530 362 {}; $cancel.DialogResult = 'Cancel'; $dialog.CancelButton = $cancel
    try { [void]$dialog.ShowDialog($Owner); return $state.Result } finally { $dialog.Dispose() }
}
try {
    New-Item -ItemType Directory -Path $appDataRoot -Force | Out-Null
    $config = Read-LauncherConfiguration $configPath
    $state = @{ Client = $config.PokerClient }
    $helpers = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($config.Helpers)) { $helpers.Add($entry) }
    $form = [Windows.Forms.Form]::new(); $form.Text = 'PokerLauncher Settings'; $form.StartPosition = 'CenterScreen'
    $form.ClientSize = [Drawing.Size]::new(650, 620); $form.Font = [Drawing.Font]::new('Segoe UI', 9)
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
    Add-Label $form 'Poker client: PokerStars (the currently supported client)' 15
    $clientLabel = [Windows.Forms.Label]::new(); $clientLabel.SetBounds(18, 42, 500, 42); $form.Controls.Add($clientLabel)
    $clientLabel.Text = if ($state.Client.Path) { $state.Client.Path } else { 'Choose the PokerStars application or updater.' }
    $choose = Add-Button $form 'Choose...' 535 38 ({
        $result = Edit-Program $form $state.Client $true
        if ($null -ne $result) { $state.Client = $result; $clientLabel.Text = $result.Path }
    }.GetNewClosure())
    Add-Label $form 'Helpers (started in this order)' 95
    $list = [Windows.Forms.ListBox]::new(); $list.SetBounds(18, 120, 500, 210); $list.DisplayMember = 'Name'; $form.Controls.Add($list)
    $refresh = { $list.Items.Clear(); foreach ($item in $helpers) { [void]$list.Items.Add($item) } }.GetNewClosure()
    & $refresh
    $add = Add-Button $form 'Add' 535 120 ({
        $result = Edit-Program $form (New-ProgramEntry '' '') $false
        if ($null -ne $result) { $helpers.Add($result); & $refresh }
    }.GetNewClosure())
    $edit = Add-Button $form 'Edit' 535 160 ({
        $i = $list.SelectedIndex
        if ($i -ge 0) { $result = Edit-Program $form $helpers[$i] $false; if ($null -ne $result) { $helpers[$i] = $result; & $refresh; $list.SelectedIndex = $i } }
    }.GetNewClosure())
    $remove = Add-Button $form 'Remove' 535 200 ({ if ($list.SelectedIndex -ge 0) { $helpers.RemoveAt($list.SelectedIndex); & $refresh } }.GetNewClosure())
    $up = Add-Button $form 'Move up' 535 240 ({
        $i = $list.SelectedIndex
        if ($i -gt 0) { $item = $helpers[$i]; $helpers.RemoveAt($i); $helpers.Insert($i - 1, $item); & $refresh; $list.SelectedIndex = $i - 1 }
    }.GetNewClosure())
    $down = Add-Button $form 'Move down' 535 280 ({
        $i = $list.SelectedIndex
        if ($i -ge 0 -and $i -lt $helpers.Count - 1) { $item = $helpers[$i]; $helpers.RemoveAt($i); $helpers.Insert($i + 1, $item); & $refresh; $list.SelectedIndex = $i + 1 }
    }.GetNewClosure())
    $login = [Windows.Forms.CheckBox]::new(); $login.Text = 'Automatically log in to PokerStars'; $login.SetBounds(18, 345, 500, 24); $form.Controls.Add($login)
    $credentials = [Windows.Forms.Panel]::new(); $credentials.SetBounds(0, 375, 640, 150); $form.Controls.Add($credentials)
    Add-Label $credentials 'PokerStars username' 0; $username = Add-Text $credentials $config.PokerStarsUsername 22
    Add-Label $credentials 'Password (leave blank to keep the saved password)' 56; $password = Add-Text $credentials '' 78; $password.UseSystemPasswordChar = $true
    $login.Add_CheckedChanged({ $credentials.Visible = $login.Checked }.GetNewClosure())
    $login.Checked = $config.LoginMode -eq 'PokerStars'; $credentials.Visible = $login.Checked
    Add-Label $form 'Launching requests administrator approval. Settings can also be edited in config.json.' 530
    $save = Add-Button $form 'Save' 430 572 ({
        $secure = $null
        try {
            $candidate = [pscustomobject]@{ SchemaVersion = 2; Integration = 'PokerStars'; PokerClient = $state.Client; Helpers = @($helpers.ToArray()); LoginMode = $(if ($login.Checked) { 'PokerStars' } else { 'Manual' }); PokerStarsUsername = $username.Text.Trim() }
            Assert-LauncherConfiguration $candidate -CheckHelpers
            if ($login.Checked) {
                if ($password.Text.Length -gt 0) {
                    $secure = ConvertTo-SecureString $password.Text -AsPlainText -Force
                    $encrypted = ConvertFrom-SecureString $secure
                    $temp = $passwordPath + '.tmp'; [IO.File]::WriteAllText($temp, $encrypted)
                    $verification = ConvertTo-SecureString ([IO.File]::ReadAllText($temp))
                    try { if ($verification.Length -ne $secure.Length) { throw 'Password verification failed.' } } finally { $verification.Dispose() }
                    Move-Item -LiteralPath $temp -Destination $passwordPath -Force
                } else {
                    $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($passwordPath))
                    if ($secure.Length -eq 0) { throw 'Enter your PokerStars password.' }
                }
            }
            Write-LauncherConfiguration $candidate $configPath
            [void][Windows.Forms.MessageBox]::Show($form, 'Settings saved. Use the PokerLauncher shortcut to launch your programs.', 'PokerLauncher')
            $form.Close()
        } catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Check settings', 'OK', 'Warning') }
        finally { if ($null -ne $secure) { $secure.Dispose() }; $password.Clear() }
    }.GetNewClosure())
    $cancel = Add-Button $form 'Cancel' 535 572 {}; $cancel.DialogResult = 'Cancel'; $form.CancelButton = $cancel
    try { [void]$form.ShowDialog() } finally { $password.Clear(); $form.Dispose() }
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
