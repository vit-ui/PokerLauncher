$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$appDataRoot = Join-Path $env:APPDATA 'PokerStarsLauncher'
$configPath = Join-Path $appDataRoot 'config.json'
$passwordPath = Join-Path $appDataRoot 'password.dpapi'
$iconPath = Join-Path $repoRoot 'assets\PokerStarsLauncher.ico'
$launcherPath = Join-Path $repoRoot 'launch.bat'

function Read-ExecutablePath {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$DefaultPath,
        [string]$CurrentPath = ''
    )

    $suggested = $CurrentPath
    if ([string]::IsNullOrWhiteSpace($suggested)) {
        $suggested = $DefaultPath
    }

    while ($true) {
        if (Test-Path -LiteralPath $suggested -PathType Leaf) {
            $answer = Read-Host "$Label path [$suggested] (Enter to accept)"
            if ([string]::IsNullOrWhiteSpace($answer)) {
                return (Resolve-Path -LiteralPath $suggested).Path
            }
        }
        else {
            Write-Host "$Label was not found at: $suggested" -ForegroundColor Yellow
            $answer = Read-Host "$Label executable path"
            if ([string]::IsNullOrWhiteSpace($answer)) {
                throw "A valid path for $Label is required."
            }
        }

        $candidate = [Environment]::ExpandEnvironmentVariables($answer.Trim().Trim('"'))
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        Write-Host "File not found: $candidate" -ForegroundColor Red
        $suggested = $candidate
    }
}

function Test-IconFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 6) {
            throw "The shortcut icon is not a valid ICO file: $Path"
        }
        $header = New-Object byte[] 4
        [void]$stream.Read($header, 0, 4)
        if ($header[0] -ne 0 -or $header[1] -ne 0 -or $header[2] -ne 1 -or $header[3] -ne 0) {
            throw "The shortcut icon is not a valid ICO file: $Path"
        }
    }
    finally {
        $stream.Dispose()
    }
    return $true
}

try {
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "Launcher entry point not found: $launcherPath"
    }

    New-Item -ItemType Directory -Path $appDataRoot -Force | Out-Null

    $existingConfig = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $existingConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        }
        catch {
            throw "Existing configuration is invalid. Move or delete '$configPath' and run setup again. $($_.Exception.Message)"
        }
    }

    Write-Host ''
    Write-Host 'PokerStarsLauncher setup' -ForegroundColor Cyan
    Write-Host 'Machine-specific settings are stored under your Windows profile, not in this repository.'
    Write-Host ''

    $usernameDefault = ''
    if ($null -ne $existingConfig) {
        $usernameDefault = [string]$existingConfig.PokerStarsUsername
    }
    if ([string]::IsNullOrWhiteSpace($usernameDefault)) {
        $username = Read-Host 'PokerStars username'
    }
    else {
        $usernameInput = Read-Host "PokerStars username [$usernameDefault] (Enter to keep)"
        $username = $usernameDefault
        if (-not [string]::IsNullOrWhiteSpace($usernameInput)) {
            $username = $usernameInput.Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($username)) {
        throw 'PokerStars username cannot be empty.'
    }

    $apps = $null
    if ($null -ne $existingConfig) {
        $apps = $existingConfig.Applications
    }

    $pokerStarsPath = Read-ExecutablePath -Label 'PokerStars updater' `
        -DefaultPath 'C:\Program Files (x86)\PokerStars\PokerStarsUpdate.exe' `
        -CurrentPath $(if ($null -ne $apps) { [string]$apps.PokerStarsUpdater } else { '' })
    $xeesterPath = Read-ExecutablePath -Label 'Xeester updater' `
        -DefaultPath 'C:\Program Files (x86)\Xeester\xeester-update.exe' `
        -CurrentPath $(if ($null -ne $apps) { [string]$apps.XeesterUpdater } else { '' })
    $starsCaptionPath = Read-ExecutablePath -Label 'StarsCaption' `
        -DefaultPath 'C:\StarsCaption\StarsCaption.exe' `
        -CurrentPath $(if ($null -ne $apps) { [string]$apps.StarsCaption } else { '' })

    $savedPasswordExists = Test-Path -LiteralPath $passwordPath -PathType Leaf
    $securePassword = Read-Host 'PokerStars password (Enter keeps the existing saved password)' -AsSecureString
    if ($securePassword.Length -gt 0) {
        $encryptedPassword = ConvertFrom-SecureString -SecureString $securePassword
        Set-Content -LiteralPath $passwordPath -Value $encryptedPassword -Encoding ASCII -NoNewline
        $roundTrip = ConvertTo-SecureString -String (Get-Content -LiteralPath $passwordPath -Raw)
        if ($roundTrip.Length -ne $securePassword.Length) {
            throw 'The encrypted password could not be verified after saving.'
        }
        $roundTrip.Dispose()
        $securePassword.Dispose()
        $securePassword = $null
    }
    elseif (-not $savedPasswordExists) {
        throw 'A password is required on the first setup run.'
    }
    else {
        $securePassword.Dispose()
        $securePassword = $null
    }

    $config = [ordered]@{
        SchemaVersion = 1
        PokerStarsUsername = $username
        Applications = [ordered]@{
            PokerStarsUpdater = $pokerStarsPath
            XeesterUpdater = $xeesterPath
            StarsCaption = $starsCaptionPath
        }
        LoginFormTimeoutSeconds = 180
        PostSubmitTimeoutSeconds = 30
    }
    $configJson = $config | ConvertTo-Json -Depth 5
    $temporaryConfig = "$configPath.tmp"
    Set-Content -LiteralPath $temporaryConfig -Value $configJson -Encoding UTF8
    Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force

    $iconAvailable = Test-IconFile -Path $iconPath
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    $shortcutPath = Join-Path $desktop 'PokerStars Launcher.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $launcherPath
    $shortcut.WorkingDirectory = $repoRoot
    $shortcut.Description = 'Launch PokerStars, Xeester, and StarsCaption, then sign in to PokerStars.'
    if ($iconAvailable) {
        $shortcut.IconLocation = "$iconPath,0"
    }
    $shortcut.Save()

    Write-Host ''
    Write-Host 'Setup completed.' -ForegroundColor Green
    Write-Host "Configuration: $configPath"
    Write-Host "Encrypted password: $passwordPath"
    Write-Host "Desktop shortcut: $shortcutPath"
    if (-not $iconAvailable) {
        Write-Host "Icon placeholder not present yet: $iconPath" -ForegroundColor Yellow
        Write-Host 'Add your ICO at that path and run setup.bat again to update the shortcut icon.' -ForegroundColor Yellow
    }
    Write-Host 'The launcher requests administrator permission when you use the shortcut.'
    exit 0
}
catch {
    Write-Host ''
    Write-Host "SETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($null -ne $securePassword) {
        $securePassword.Dispose()
    }
}
