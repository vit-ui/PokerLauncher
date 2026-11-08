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

    if ($Root.Reused) {
        if (-not (Test-ApplicationRunning $Root.ApplicationPath)) { $Root.ClosedNormally = $true }
        return $true
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
    }

    if ($null -ne $Root.ApplicationProcess) {
        $Root.ApplicationProcess.Refresh()
        if (-not $Root.ApplicationProcess.HasExited) {
            if ($rootExited -and -not $Root.HandoffLogged) {
                Write-LauncherLog "Confirmed $($Root.Name) handoff: '$($Root.ApplicationPath)' is running in this launcher's process job (updater exit code $rootExitCode)."
                $Root.HandoffLogged = $true
            }
            return $true
        }
        if ($Root.ApplicationProcess.ExitCode -ne 0) {
            throw "Application '$($Root.ApplicationPath)' exited unexpectedly with code $($Root.ApplicationProcess.ExitCode)."
        }
    }

    # Keep the verified process handle, including its exit code. Once startup
    # was observed, a normal close must not become a failed updater handoff.
    $applicationRunning = $false
    $applicationName = [IO.Path]::GetFileNameWithoutExtension($Root.ApplicationPath)
    foreach ($candidate in @(Get-Process -Name $applicationName -ErrorAction SilentlyContinue)) {
        $retain = $false
        try {
            if (-not $applicationRunning -and [PokerStarsLauncherProcessJob]::IsRunningInJob($Job, $candidate, $Root.ApplicationPath)) {
                if ($null -ne $Root.ApplicationProcess) { $Root.ApplicationProcess.Dispose() }
                $Root.ApplicationProcess = $candidate
                $Root.ClosedNormally = $false
                $retain = $true
                $applicationRunning = $true
                Write-LauncherLog "Confirmed application startup: '$($Root.ApplicationPath)' (PID $($candidate.Id))."
                if ($rootExited -and -not $Root.HandoffLogged) {
                    Write-LauncherLog "Confirmed $($Root.Name) handoff: '$($Root.ApplicationPath)' is running in this launcher's process job (updater exit code $rootExitCode)."
                    $Root.HandoffLogged = $true
                }
            }
        }
        finally { if (-not $retain) { $candidate.Dispose() } }
    }

    if ($applicationRunning) { return $true }
    if ($null -ne $Root.ApplicationProcess) {
        if (-not $Root.ClosedNormally) {
            Write-LauncherLog "Application closed normally after confirmed startup: '$($Root.ApplicationPath)'."
            $Root.ClosedNormally = $true
        }
        return $true
    }
    if ($rootExited -and ($ElapsedSeconds - $Root.ExitObservedAt) -ge $HandoffTimeoutSeconds) {
        throw "$($Root.Name) exited with code $rootExitCode, but '$($Root.ApplicationPath)' did not start in this launcher's process job within $HandoffTimeoutSeconds seconds."
    }
    return $false
}

function Test-ApplicationRunning {
    param([string]$Path)
    foreach ($candidate in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Path)) -ErrorAction SilentlyContinue)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($candidate.MainModule.FileName) -and [IO.Path]::GetFullPath($candidate.MainModule.FileName) -ieq $Path -and -not $candidate.HasExited) { return $true }
        } catch [ComponentModel.Win32Exception] { throw "Cannot inspect existing application '$Path'." }
        catch [InvalidOperationException] { continue }
        finally { $candidate.Dispose() }
    }
    return $false
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
    Write-LauncherLog "Launcher run started. Start time UTC: $runStartedUtcText"
    Remove-Item -LiteralPath (Join-Path $logDirectory 'login-error.txt') -Force -ErrorAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'ProcessJob.ps1')
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Configuration not found: $configPath. Run Configure PokerStarsLauncher from the Start Menu first."
    }
    if (-not (Test-Path -LiteralPath $loginScript -PathType Leaf)) {
        throw "PokerStars login helper not found: $loginScript"
    }
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell executable was not found: $windowsPowerShell"
    }

    . (Join-Path $PSScriptRoot 'Configuration.ps1')
    $config = Read-LauncherConfiguration $configPath
    Assert-LauncherConfiguration $config
    $launchItems = @($config.PokerClient) + @($config.Helpers)
    $helperFailures = [Collections.Generic.List[string]]::new()
    $clientReused = Test-ApplicationRunning (Resolve-ProgramEntry $config.PokerClient).ApplicationPath
    $automaticLogin = $config.LoginMode -eq 'PokerStars' -and -not $clientReused
    if ($automaticLogin) {
        $savedPassword = $null
        try {
            $savedPassword = ConvertTo-SecureString -String ([IO.File]::ReadAllText((Join-Path $appDataRoot 'password.dpapi')).Trim())
            if ($savedPassword.Length -eq 0) { throw 'Empty password' }
        } catch { throw 'The saved password is missing or cannot be decrypted under this Windows account.' }
        finally { if ($null -ne $savedPassword) { $savedPassword.Dispose() } }
    }

    $nativeError = $null
    $jobHandle = [PokerStarsLauncherProcessJob]::Create($jobName, [ref]$nativeError)
    if ($jobHandle -eq [IntPtr]::Zero) {
        throw "Could not create the process job used for failure cleanup: $nativeError"
    }

    Write-LauncherLog 'Failure cleanup uses a Windows Job Object. Each process is assigned while suspended before it can spawn descendants.'

    for ($index = 0; $index -lt $launchItems.Count; $index++) {
        $isClient = $index -eq 0
        $item = Resolve-ProgramEntry $launchItems[$index]
        try {
            $reused = Test-ApplicationRunning $item.ApplicationPath
            $processId = 0; $processHandleId = 0
            if (-not $reused) {
                Assert-ProgramFiles $item
                $started = [PokerStarsLauncherProcessJob]::StartProcess(
                    $jobHandle, $item.Path, $item.Arguments, $item.WorkingDirectory, $false,
                    [ref]$processId, [ref]$processHandleId, [ref]$nativeError
                )
                if (-not $started) { throw "Could not start $($item.Name): $nativeError" }
                Write-LauncherLog "Started $($item.Name): $($item.Path) (PID $processId)."
            } else { Write-LauncherLog "Reusing application: $($item.Name) ($($item.ApplicationPath))." }
            $rootProcesses += [PSCustomObject]@{
                Name = $item.Name; ProcessId = [int]$processId; ProcessHandleId = [int]$processHandleId
                ApplicationPath = $item.ApplicationPath; IsUpdater = $item.Path -ine $item.ApplicationPath
                ExitObservedAt = -1.0; HandoffLogged = $false; ApplicationProcess = $null
                ClosedNormally = $false; Reused = $reused; IsClient = $isClient; Failed = $false
            }
        } catch {
            if ($isClient) { throw }
            $helperFailures.Add("$($item.Name): $($_.Exception.Message)")
            Write-LauncherLog "Helper failure: $($helperFailures[$helperFailures.Count - 1])"
        }
    }

    if ($automaticLogin) {
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

    }
    $pokerStarsClosedAt = -1.0
    $loginFailureAt = -1.0
    $cancelled = $false
    while ($true) {
        if ($startupTimer.Elapsed.TotalSeconds -ge $startupTimeoutSeconds) {
            $client = $rootProcesses[0]
            if (-not (Test-LauncherApplication $client $jobHandle $startupTimer.Elapsed.TotalSeconds) -or ($automaticLogin -and -not $loginExited)) {
                throw "Application startup and PokerStars login did not complete within $startupTimeoutSeconds seconds."
            }
            foreach ($root in $rootProcesses) {
                if ($root.IsClient -or $root.Failed) { continue }
                try { $ready = Test-LauncherApplication $root $jobHandle $startupTimer.Elapsed.TotalSeconds }
                catch { $ready = $false }
                if (-not $ready) {
                    $root.Failed = $true
                    $helperFailures.Add("$($root.Name): startup timed out.")
                }
            }
            break
        }
        $allApplicationsStarted = $true
        foreach ($root in $rootProcesses) {
            if ($root.Failed) { continue }
            try {
                if (-not (Test-LauncherApplication -Root $root -Job $jobHandle -ElapsedSeconds $startupTimer.Elapsed.TotalSeconds)) { $allApplicationsStarted = $false }
            } catch {
                if ($root.IsClient) { throw }
                $root.Failed = $true
                $helperFailures.Add("$($root.Name): $($_.Exception.Message)")
                Write-LauncherLog "Helper failure: $($helperFailures[$helperFailures.Count - 1])"
            }
        }

        if ($rootProcesses[0].ClosedNormally) {
            if ($pokerStarsClosedAt -lt 0) { $pokerStarsClosedAt = $startupTimer.Elapsed.TotalSeconds }
            # Allow a short handoff to a replacement PokerStars process.
            if (($startupTimer.Elapsed.TotalSeconds - $pokerStarsClosedAt) -ge 1) {
                $stopError = $null
                if ($automaticLogin -and -not [PokerStarsLauncherProcessJob]::StopProcess($loginProcessHandleId, [ref]$stopError)) { throw $stopError }
                Write-LauncherLog 'Launch cancelled: PokerStars closed normally during startup. Login automation stopped; other applications were left alone.'
                Remove-Item -LiteralPath (Join-Path $logDirectory 'login-error.txt') -Force -ErrorAction SilentlyContinue
                $cancelled = $true
                break
            }
        }
        else { $pokerStarsClosedAt = -1.0 }

        if (-not $automaticLogin) {
            if ($allApplicationsStarted) { break }
            Start-Sleep -Milliseconds 300
            continue
        }
        [uint32]$loginExitCode = 0
        $loginError = $null
        $loginExited = [PokerStarsLauncherProcessJob]::HasExited(
            [int]$loginProcessHandleId, [int]$loginProcessId, [ref]$loginExitCode, [ref]$loginError
        )
        if (-not [string]::IsNullOrWhiteSpace($loginError)) { throw $loginError }
        if ($loginExited) {
            if ($loginExitCode -ne 0) {
                if ($loginFailureAt -lt 0) { $loginFailureAt = $startupTimer.Elapsed.TotalSeconds }
                if (($startupTimer.Elapsed.TotalSeconds - $loginFailureAt) -ge 1 -and -not $rootProcesses[0].ClosedNormally) {
                    throw "PokerStars login helper failed with exit code $loginExitCode. See '$((Join-Path $logDirectory 'login-error.txt'))'."
                }
            }
            elseif ($allApplicationsStarted -and -not $rootProcesses[0].ClosedNormally) { break }
        }
        Start-Sleep -Milliseconds 300
    }

    if (-not $cancelled) {
        Write-LauncherLog 'Launcher completed successfully. Application startup and login submission were confirmed.'
        Write-Host 'Application startup completed.' -ForegroundColor Green
    }
    [PokerStarsLauncherProcessJob]::CloseProcessHandles()
    [PokerStarsLauncherProcessJob]::CloseJob($jobHandle)
    $jobHandle = [IntPtr]::Zero
    if ($helperFailures.Count -gt 0) {
        Write-LauncherLog ("Helper failures: " + ($helperFailures -join '; '))
        Write-Host ("Some helpers could not start:`r`n" + ($helperFailures -join "`r`n"))
        exit 3 # Partial success: host reports helpers without fatal cleanup.
    }
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
finally {
    foreach ($root in $rootProcesses) {
        if ($null -ne $root.ApplicationProcess) { $root.ApplicationProcess.Dispose() }
    }
}
