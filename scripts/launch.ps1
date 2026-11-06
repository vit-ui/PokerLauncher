$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$appDataRoot = Join-Path $env:APPDATA 'PokerStarsLauncher'
$configPath = Join-Path $appDataRoot 'config.json'
$logDirectory = Join-Path $env:LOCALAPPDATA 'PokerStarsLauncher\logs'
$logPath = Join-Path $logDirectory 'launcher.log'
$loginScript = Join-Path $PSScriptRoot 'PokerStarsLogin.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-LauncherLog {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Message
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 }
    catch { Write-Warning "Could not write launcher log: $($_.Exception.Message)" }
}

function Test-LauncherApplication {
    param($Root, [IntPtr]$Job, [double]$ElapsedSeconds, [int]$HandoffTimeoutSeconds = 30)

    $applicationRunning = $false
    $applicationName = [IO.Path]::GetFileNameWithoutExtension($Root.ApplicationPath)
    foreach ($candidate in @(Get-Process -Name $applicationName -ErrorAction SilentlyContinue)) {
        try {
            if ([PokerStarsLauncherProcessJob]::IsRunningInJob($Job, $candidate, $Root.ApplicationPath)) {
                $applicationRunning = $true
            }
        }
        finally { $candidate.Dispose() }
    }

    [uint32]$rootExitCode = 0
    $rootError = $null
    $rootExited = [PokerStarsLauncherProcessJob]::HasExited(
        [int]$Root.ProcessHandleId, [int]$Root.ProcessId, [ref]$rootExitCode, [ref]$rootError
    )
    if (-not [string]::IsNullOrWhiteSpace($rootError)) { throw $rootError }
    if ($rootExited) {
        if ($Root.ExitObservedAt -lt 0) {
            $Root.ExitObservedAt = $ElapsedSeconds
            Write-LauncherLog "$($Root.Name) exited with code $rootExitCode; checking the application handoff."
        }
        if (-not $Root.IsUpdater -and $rootExitCode -ne 0) {
            throw "$($Root.Name) exited with code $rootExitCode."
        }
        if ($applicationRunning) {
            if (-not $Root.HandoffLogged) {
                Write-LauncherLog "Confirmed $($Root.Name) handoff: '$($Root.ApplicationPath)' is running in this launcher's process job (updater exit code $rootExitCode)."
                $Root.HandoffLogged = $true
            }
        }
        elseif (($ElapsedSeconds - $Root.ExitObservedAt) -ge $HandoffTimeoutSeconds) {
            throw "$($Root.Name) exited with code $rootExitCode, but '$($Root.ApplicationPath)' is not running in this launcher's process job after $HandoffTimeoutSeconds seconds."
        }
    }
    return $applicationRunning
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The Go application requests UAC before invoking this controller. Keeping
# elevation here as well would create a second controller and break its error
# reporting, so fail explicitly if the token is not elevated.
if (-not (Test-IsAdministrator)) {
    throw 'The launcher controller must be started with administrator privileges.'
}

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

. (Join-Path $PSScriptRoot 'ProcessJob.ps1')

$jobHandle = [IntPtr]::Zero
$rootProcesses = @()
$loginProcessId = 0
$failureMessage = $null
$runStartedUtc = [DateTime]::UtcNow
$runStartedUtcText = $runStartedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
$jobName = 'Local\PokerStarsLauncher-' + [Guid]::NewGuid().ToString('N')
$startupTimer = [Diagnostics.Stopwatch]::StartNew()
$startupTimeoutSeconds = 240

try {
    Remove-Item -LiteralPath (Join-Path $logDirectory 'login-error.txt') -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Configuration not found: $configPath. Run Configure PokerStarsLauncher from the Start Menu first."
    }
    if (-not (Test-Path -LiteralPath $loginScript -PathType Leaf)) {
        throw "PokerStars login helper not found: $loginScript"
    }
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell executable was not found: $windowsPowerShell"
    }

    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$config.SchemaVersion -ne 1) {
        throw 'Unsupported configuration schema. Run Configure PokerStarsLauncher from the Start Menu again.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.PokerStarsUsername)) {
        throw 'PokerStars username is missing. Run Configure PokerStarsLauncher from the Start Menu again.'
    }
    $savedPassword = $null
    try {
        $passwordPath = Join-Path $appDataRoot 'password.dpapi'
        $savedPassword = ConvertTo-SecureString -String ([IO.File]::ReadAllText($passwordPath).Trim())
        if ($savedPassword.Length -eq 0) { throw 'The saved password is empty.' }
    }
    catch { throw 'The saved password is missing or cannot be decrypted under this Windows account. Run Configure PokerStarsLauncher from the Start Menu again.' }
    finally { if ($null -ne $savedPassword) { $savedPassword.Dispose() } }

    $launchItems = @(
        [PSCustomObject]@{ Name = 'PokerStars updater'; Path = [string]$config.Applications.PokerStarsUpdater; Application = 'PokerStars.exe'; IsUpdater = $true },
        [PSCustomObject]@{ Name = 'Xeester updater'; Path = [string]$config.Applications.XeesterUpdater; Application = 'jre\bin\xeester.exe'; IsUpdater = $true },
        [PSCustomObject]@{ Name = 'StarsCaption'; Path = [string]$config.Applications.StarsCaption; Application = ''; IsUpdater = $false }
    )

    foreach ($item in $launchItems) {
        if ([string]::IsNullOrWhiteSpace($item.Path) -or -not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            throw "Configured executable for $($item.Name) was not found: $($item.Path). Run Configure PokerStarsLauncher from the Start Menu to correct it."
        }
        $item.Path = [IO.Path]::GetFullPath($item.Path)
    }

    # The login helper intentionally targets only a PokerStars process created
    # during this launcher invocation. Refuse to start if an older PokerStars
    # process is still present, instead of waiting 180 seconds for a dialog in
    # a process the launcher does not own.
    $existingPokerStars = @(Get-Process -Name 'PokerStars' -ErrorAction SilentlyContinue)
    if ($existingPokerStars.Count -gt 0) {
        Write-LauncherLog 'Launch skipped: PokerStars is already running. Existing applications were left running.'
        Write-Host 'PokerStars is already running. Close PokerStars when you are ready, then open PokerStars Launcher again.'
        exit 2 # Expected condition; the Go host shows an informational dialog.
    }

    $nativeError = $null
    $jobHandle = [PokerStarsLauncherProcessJob]::Create($jobName, [ref]$nativeError)
    if ($jobHandle -eq [IntPtr]::Zero) {
        throw "Could not create the process job used for failure cleanup: $nativeError"
    }

    Write-LauncherLog "Launcher started elevated. Start time UTC: $runStartedUtcText"
    Write-LauncherLog 'Failure cleanup uses a Windows Job Object. Each process is assigned while suspended before it can spawn descendants.'

    # Preserve the original BAT behavior: launch these three in order, with no
    # waiting for one updater to finish before starting the next application.
    foreach ($item in $launchItems) {
        $processId = 0
        $processHandleId = 0
        $applicationWorkingDirectory = [System.IO.Path]::GetDirectoryName($item.Path)
        $started = [PokerStarsLauncherProcessJob]::StartProcess(
            $jobHandle, $item.Path, '', $applicationWorkingDirectory, $false,
            [ref]$processId, [ref]$processHandleId, [ref]$nativeError
        )
        if (-not $started) {
            throw "Could not start $($item.Name): $nativeError"
        }
        $rootProcesses += [PSCustomObject]@{
            Name = $item.Name
            ProcessId = [int]$processId
            ProcessHandleId = [int]$processHandleId
            ApplicationPath = $(if ($item.IsUpdater) { Join-Path $applicationWorkingDirectory $item.Application } else { $item.Path })
            IsUpdater = $item.IsUpdater
            ExitObservedAt = -1.0
            HandoffLogged = $false
        }
        Write-LauncherLog "Started $($item.Name): $($item.Path) (PID $processId)."
    }

    $loginArguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $loginScript + '" -RunStartedUtc "' + $runStartedUtcText + '" -JobName "' + $jobName + '" -PokerStarsPath "' + $rootProcesses[0].ApplicationPath + '"'
    $loginProcessId = 0
    $loginProcessHandleId = 0
    $loginStarted = [PokerStarsLauncherProcessJob]::StartProcess(
        $jobHandle, $windowsPowerShell, $loginArguments, $repoRoot, $true,
        [ref]$loginProcessId, [ref]$loginProcessHandleId, [ref]$nativeError
    )
    if (-not $loginStarted) {
        throw "Could not start the PokerStars login helper: $nativeError"
    }
    Write-LauncherLog "Started PokerStars login helper (PID $loginProcessId)."

    while ($true) {
        if ($startupTimer.Elapsed.TotalSeconds -ge $startupTimeoutSeconds) {
            throw "Application startup and PokerStars login did not complete within $startupTimeoutSeconds seconds. See launcher.log and login.log for the last observed state."
        }
        $allApplicationsRunning = $true
        foreach ($root in $rootProcesses) {
            if (-not (Test-LauncherApplication -Root $root -Job $jobHandle -ElapsedSeconds $startupTimer.Elapsed.TotalSeconds)) {
                $allApplicationsRunning = $false
            }
        }

        [uint32]$loginExitCode = 0
        $loginError = $null
        $loginExited = [PokerStarsLauncherProcessJob]::HasExited(
            [int]$loginProcessHandleId, [int]$loginProcessId, [ref]$loginExitCode, [ref]$loginError
        )
        if (-not [string]::IsNullOrWhiteSpace($loginError)) { throw $loginError }
        if ($loginExited) {
            if ($loginExitCode -ne 0) {
                throw "PokerStars login helper failed with exit code $loginExitCode. See '$((Join-Path $logDirectory 'login-error.txt'))'."
            }
            if ($allApplicationsRunning) { break }
        }
        Start-Sleep -Milliseconds 300
    }

    Write-LauncherLog 'Launcher completed successfully. Applications remain running.'
    Write-Host 'PokerStars login was submitted successfully. The applications remain running.' -ForegroundColor Green
    [PokerStarsLauncherProcessJob]::CloseProcessHandles()
    [PokerStarsLauncherProcessJob]::CloseJob($jobHandle)
    $jobHandle = [IntPtr]::Zero
    exit 0
}
catch {
    $failureMessage = $_.Exception.Message
    if ($_.InvocationInfo.ScriptLineNumber -gt 0) {
        $failureLine = $_.InvocationInfo.Line.Trim()
        $failureMessage = '{0} (launch.ps1 line {1}: {2})' -f $failureMessage, $_.InvocationInfo.ScriptLineNumber, $failureLine
    }
    if (Test-Path -LiteralPath $logDirectory -PathType Container) {
        Write-LauncherLog "LAUNCHER FAILURE: $failureMessage"
    }

    $cleanupError = $null
    if ($jobHandle -ne [IntPtr]::Zero) {
        $terminated = [PokerStarsLauncherProcessJob]::Terminate($jobHandle, [ref]$cleanupError)
        if ($terminated) {
            Write-LauncherLog 'Failure cleanup: Windows terminated the entire launcher process job.'
        }
        else {
            Write-LauncherLog "CRITICAL: $cleanupError"
        }
        [PokerStarsLauncherProcessJob]::CloseProcessHandles()
        [PokerStarsLauncherProcessJob]::CloseJob($jobHandle)
        $jobHandle = [IntPtr]::Zero
    }

    Write-Host ''
    Write-Host "LAUNCHER FAILED: $failureMessage" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($cleanupError)) {
        Write-Host "PROCESS CLEANUP FAILED: $cleanupError" -ForegroundColor Red
    }
    Write-Host "See launcher log: $logPath" -ForegroundColor Yellow
    exit 1
}
