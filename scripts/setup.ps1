$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$appDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$appDataRoot = Join-Path $env:APPDATA 'PokerStarsLauncher'
$configPath = Join-Path $appDataRoot 'config.json'
$passwordPath = Join-Path $appDataRoot 'password.dpapi'

function Read-ExistingConfiguration {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        throw "The existing configuration is invalid: $($_.Exception.Message)`r`nMove or delete '$configPath' only if you intend to configure the application from scratch."
    }
}

function New-PathRow {
    param(
        [System.Windows.Forms.Form]$Form,
        [int]$Top,
        [string]$LabelText,
        [string]$DefaultValue
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $LabelText
    $label.Location = [System.Drawing.Point]::new(18, $Top)
    $label.Size = [System.Drawing.Size]::new(550, 20)
    $Form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Text = $DefaultValue
    $textBox.Location = [System.Drawing.Point]::new(18, ($Top + 23))
    $textBox.Size = [System.Drawing.Size]::new(475, 24)
    $Form.Controls.Add($textBox)

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'Browse...'
    $browse.Location = [System.Drawing.Point]::new(503, ($Top + 21))
    $browse.Size = [System.Drawing.Size]::new(82, 27)
    $browse.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select the application executable'
        $dialog.Filter = 'Executable files (*.exe)|*.exe|All files (*.*)|*.*'
        $dialog.CheckFileExists = $true
        $dialog.FileName = $textBox.Text
        if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $textBox.Text = $dialog.FileName
        }
        $dialog.Dispose()
    }.GetNewClosure())
    $Form.Controls.Add($browse)

    return $textBox
}

try {
    New-Item -ItemType Directory -Path $appDataRoot -Force | Out-Null
    $existing = Read-ExistingConfiguration

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PokerStarsLauncher Setup'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = [System.Drawing.Size]::new(605, 535)
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 9)

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = 'Configure your PokerStars applications'
    $heading.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 12)
    $heading.Location = [System.Drawing.Point]::new(18, 14)
    $heading.Size = [System.Drawing.Size]::new(560, 28)
    $form.Controls.Add($heading)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Settings are saved to your Windows profile. The password is protected with Windows DPAPI.'
    $intro.Location = [System.Drawing.Point]::new(18, 44)
    $intro.Size = [System.Drawing.Size]::new(560, 34)
    $form.Controls.Add($intro)

    $usernameLabel = New-Object System.Windows.Forms.Label
    $usernameLabel.Text = 'PokerStars username'
    $usernameLabel.Location = [System.Drawing.Point]::new(18, 86)
    $usernameLabel.Size = [System.Drawing.Size]::new(550, 20)
    $form.Controls.Add($usernameLabel)

    $usernameBox = New-Object System.Windows.Forms.TextBox
    if ($null -ne $existing) { $usernameBox.Text = [string]$existing.PokerStarsUsername }
    $usernameBox.Location = [System.Drawing.Point]::new(18, 109)
    $usernameBox.Size = [System.Drawing.Size]::new(567, 24)
    $form.Controls.Add($usernameBox)

    $passwordLabel = New-Object System.Windows.Forms.Label
    $passwordLabel.Text = 'PokerStars password'
    $passwordLabel.Location = [System.Drawing.Point]::new(18, 145)
    $passwordLabel.Size = [System.Drawing.Size]::new(550, 20)
    $form.Controls.Add($passwordLabel)

    $passwordBox = New-Object System.Windows.Forms.TextBox
    $passwordBox.UseSystemPasswordChar = $true
    $passwordBox.Location = [System.Drawing.Point]::new(18, 168)
    $passwordBox.Size = [System.Drawing.Size]::new(567, 24)
    $form.Controls.Add($passwordBox)

    $passwordHint = New-Object System.Windows.Forms.Label
    if (Test-Path -LiteralPath $passwordPath -PathType Leaf) {
        $passwordHint.Text = 'Leave blank to keep the existing saved password.'
    }
    else {
        $passwordHint.Text = 'Enter the password to save it securely for automatic login.'
    }
    $passwordHint.ForeColor = [System.Drawing.Color]::DimGray
    $passwordHint.Location = [System.Drawing.Point]::new(18, 194)
    $passwordHint.Size = [System.Drawing.Size]::new(567, 20)
    $form.Controls.Add($passwordHint)

    $apps = if ($null -ne $existing) { $existing.Applications } else { $null }
    $pokerStarsDefault = if ($null -ne $apps -and $apps.PokerStarsUpdater) { [string]$apps.PokerStarsUpdater } else { 'C:\Program Files (x86)\PokerStars\PokerStarsUpdate.exe' }
    $xeesterDefault = if ($null -ne $apps -and $apps.XeesterUpdater) { [string]$apps.XeesterUpdater } else { 'C:\Program Files (x86)\Xeester\xeester-update.exe' }
    $starsCaptionDefault = if ($null -ne $apps -and $apps.StarsCaption) { [string]$apps.StarsCaption } else { 'C:\StarsCaption\StarsCaption.exe' }

    $pokerStarsBox = New-PathRow -Form $form -Top 222 -LabelText 'PokerStars updater' -DefaultValue $pokerStarsDefault
    $xeesterBox = New-PathRow -Form $form -Top 285 -LabelText 'Xeester updater' -DefaultValue $xeesterDefault
    $starsCaptionBox = New-PathRow -Form $form -Top 348 -LabelText 'StarsCaption' -DefaultValue $starsCaptionDefault

    $footer = New-Object System.Windows.Forms.Label
    $footer.Text = 'The Desktop shortcut will request administrator permission when launched.'
    $footer.ForeColor = [System.Drawing.Color]::DimGray
    $footer.Location = [System.Drawing.Point]::new(18, 414)
    $footer.Size = [System.Drawing.Size]::new(567, 30)
    $form.Controls.Add($footer)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = 'Save'
    $saveButton.Location = [System.Drawing.Point]::new(414, 475)
    $saveButton.Size = [System.Drawing.Size]::new(82, 32)
    $saveButton.DialogResult = [System.Windows.Forms.DialogResult]::None
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = [System.Drawing.Point]::new(503, 475)
    $cancelButton.Size = [System.Drawing.Size]::new(82, 32)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $securePassword = $null
    $saveButton.Add_Click({
        try {
            $username = $usernameBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($username)) { throw 'Enter your PokerStars username.' }

            $paths = @(
                [PSCustomObject]@{ Label = 'PokerStars updater'; Value = $pokerStarsBox.Text },
                [PSCustomObject]@{ Label = 'Xeester updater'; Value = $xeesterBox.Text },
                [PSCustomObject]@{ Label = 'StarsCaption'; Value = $starsCaptionBox.Text }
            )
            foreach ($item in $paths) {
                $candidate = [Environment]::ExpandEnvironmentVariables($item.Value.Trim().Trim('"'))
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    throw ("{0} was not found:`r`n{1}" -f $item.Label, $candidate)
                }
            }

            $passwordText = $passwordBox.Text
            $savedPasswordExists = Test-Path -LiteralPath $passwordPath -PathType Leaf
            if ($passwordText.Length -eq 0 -and -not $savedPasswordExists) {
                throw 'Enter your PokerStars password for the first setup.'
            }
            if ($passwordText.Length -eq 0 -and $savedPasswordExists) {
                $existingSecurePassword = $null
                try {
                    $existingSecurePassword = ConvertTo-SecureString -String ([System.IO.File]::ReadAllText($passwordPath))
                    if ($existingSecurePassword.Length -le 0) { throw 'The saved password is empty.' }
                }
                catch {
                    throw 'The existing encrypted password cannot be decrypted under this Windows account. Enter the password again to replace it.'
                }
                finally {
                    if ($null -ne $existingSecurePassword) { $existingSecurePassword.Dispose() }
                }
            }
            if ($passwordText.Length -gt 0) {
                $securePassword = New-Object System.Security.SecureString
                foreach ($character in $passwordText.ToCharArray()) { $securePassword.AppendChar($character) }
                $securePassword.MakeReadOnly()
                $encrypted = ConvertFrom-SecureString -SecureString $securePassword
                $temporaryPassword = "$passwordPath.tmp"
                [System.IO.File]::WriteAllText($temporaryPassword, $encrypted, [System.Text.Encoding]::ASCII)
                Move-Item -LiteralPath $temporaryPassword -Destination $passwordPath -Force
                $verification = ConvertTo-SecureString -String ([System.IO.File]::ReadAllText($passwordPath))
                if ($verification.Length -ne $securePassword.Length) {
                    $verification.Dispose()
                    throw 'The encrypted password could not be verified after saving.'
                }
                $verification.Dispose()
                $securePassword.Dispose()
                $securePassword = $null
                $passwordBox.Clear()
                $passwordText = $null
            }

            $config = [ordered]@{
                SchemaVersion = 1
                PokerStarsUsername = $username
                Applications = [ordered]@{
                    PokerStarsUpdater = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($pokerStarsBox.Text.Trim().Trim('"')))
                    XeesterUpdater = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($xeesterBox.Text.Trim().Trim('"')))
                    StarsCaption = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($starsCaptionBox.Text.Trim().Trim('"')))
                }
            }
            $json = $config | ConvertTo-Json -Depth 5
            $temporaryConfig = "$configPath.tmp"
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($temporaryConfig, $json, $utf8NoBom)
            Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force

            [System.Windows.Forms.MessageBox]::Show(
                $form,
                'Configuration saved. Use the PokerStars Launcher shortcut on your Desktop to start the applications.',
                'Setup complete',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                $_.Exception.Message,
                'PokerStarsLauncher setup',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
        finally {
            if ($null -ne $securePassword) { $securePassword.Dispose(); $securePassword = $null }
            $passwordText = $null
            $passwordBox.Clear()
        }
    }.GetNewClosure())

    $form.AcceptButton = $saveButton
    $form.Add_Shown({ $usernameBox.Focus() }.GetNewClosure())
    [void]$form.ShowDialog()
    $passwordBox.Clear()
    $form.Dispose()
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
