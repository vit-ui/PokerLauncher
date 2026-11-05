$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$appDataRoot = Join-Path $env:APPDATA 'PokerStarsLauncher'
$configPath = Join-Path $appDataRoot 'config.json'
$logDirectory = Join-Path $env:LOCALAPPDATA 'PokerStarsLauncher\logs'
$logPath = Join-Path $logDirectory 'launcher.log'
$loginScript = Join-Path $PSScriptRoot 'PokerStarsLogin.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-LauncherLog {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Elevate the controller once. All three applications and the login helper
# inherit the elevated token from this process.
if (-not (Test-IsAdministrator)) {
    try {
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments `
            -Verb RunAs -WorkingDirectory $repoRoot | Out-Null
        exit 0
    }
    catch {
        Write-Host "Administrator permission was not granted. Launcher cancelled. $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to close' | Out-Null
        exit 1
    }
}

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

$trackedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
$parentByProcessId = @{}
$startTimeByProcessId = @{}
$rootProcesses = @()
$failureMessage = $null
$runStartedUtc = [DateTime]::UtcNow
$runStartedUtcText = $runStartedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

function Add-TrackedProcess {
    param(
        [int]$ProcessId,
        [int]$ParentProcessId,
        [datetime]$StartTimeUtc = [DateTime]::MinValue
    )
    if ($ProcessId -le 0) { return }
    if ($trackedProcessIds.Add($ProcessId)) {
        $parentByProcessId[$ProcessId] = $ParentProcessId
        $startTimeByProcessId[$ProcessId] = $StartTimeUtc
    }
}

function Update-TrackedProcessTree {
    try {
        $snapshot = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    }
    catch {
        Write-LauncherLog "WARNING: Could not inspect the process tree: $($_.Exception.Message)"
        return
    }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($item in $snapshot) {
            $processId = [int]$item.ProcessId
            $parentId = [int]$item.ParentProcessId
            if ($trackedProcessIds.Contains($parentId) -and -not $trackedProcessIds.Contains($processId)) {
                $creationUtc = [DateTime]::MinValue
                try {
                    if (-not [string]::IsNullOrWhiteSpace([string]$item.CreationDate)) {
                        $creationUtc = [Management.ManagementDateTimeConverter]::ToDateTime([string]$item.CreationDate).ToUniversalTime()
                    }
                }
                catch { }
                Add-TrackedProcess -ProcessId $processId -ParentProcessId $parentId -StartTimeUtc $creationUtc
                $changed = $true
            }
        }
    }
}

function Get-TrackedProcessDepth {
    param([int]$ProcessId)
    $depth = 0
    $current = $ProcessId
    $visited = [System.Collections.Generic.HashSet[int]]::new()
    while ($parentByProcessId.ContainsKey($current) -and $visited.Add($current)) {
        $parent = [int]$parentByProcessId[$current]
        if ($parent -le 0 -or -not $trackedProcessIds.Contains($parent)) { break }
        $depth++
        $current = $parent
    }
    return $depth
}

function Stop-LaunchedProcesses {
    Write-LauncherLog 'Failure cleanup: collecting processes started by this launcher invocation.'
    Update-TrackedProcessTree
    $orderedProcesses = foreach ($trackedId in $trackedProcessIds) {
        [PSCustomObject]@{ ProcessId = [int]$trackedId; Depth = (Get-TrackedProcessDepth -ProcessId ([int]$trackedId)) }
    }
    $processIds = @($orderedProcesses | Sort-Object -Property Depth -Descending | Select-Object -ExpandProperty ProcessId)

    foreach ($processId in $processIds) {
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            if (-not $process.HasExited) {
                $expectedStart = [datetime]$startTimeByProcessId[$processId]
                if ($expectedStart -ne [DateTime]::MinValue) {
                    $actualStart = $process.StartTime.ToUniversalTime()
                    if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
                        Write-LauncherLog "Cleanup skipped PID $processId because its process identity changed."
                        continue
                    }
                }
                Stop-Process -Id $processId -Force -ErrorAction Stop
                Write-LauncherLog "Terminated launched process PID $processId ($($process.ProcessName))."
            }
        }
        catch {
            if ($_.Exception.Message -match 'Cannot find a process|No process was found') {
                Write-LauncherLog "Cleanup note: PID $processId was already gone."
            }
            else {
                Write-LauncherLog "WARNING: Could not terminate PID ${processId}: $($_.Exception.Message)"
            }
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Configuration not found: $configPath. Run setup.bat first."
    }
    if (-not (Test-Path -LiteralPath $loginScript -PathType Leaf)) {
        throw "PokerStars login helper not found: $loginScript"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ([int]$config.SchemaVersion -ne 1) {
        throw 'Unsupported configuration schema. Run setup.bat again with this version of PokerStarsLauncher.'
    }

    $launchItems = @(
        [PSCustomObject]@{ Name = 'PokerStars updater'; Path = [string]$config.Applications.PokerStarsUpdater },
        [PSCustomObject]@{ Name = 'Xeester updater'; Path = [string]$config.Applications.XeesterUpdater },
        [PSCustomObject]@{ Name = 'StarsCaption'; Path = [string]$config.Applications.StarsCaption }
    )

    foreach ($item in $launchItems) {
        if ([string]::IsNullOrWhiteSpace($item.Path) -or -not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            throw "Configured executable for $($item.Name) was not found: $($item.Path). Run setup.bat to correct it."
        }
    }

    Write-LauncherLog "Launcher started elevated. Start time UTC: $runStartedUtcText"

    # Preserve the original BAT behavior: launch in this order, without waiting
    # for an updater to finish before starting the next application.
    foreach ($item in $launchItems) {
        $process = Start-Process -FilePath $item.Path -WorkingDirectory $repoRoot -PassThru
        $processStartUtc = [DateTime]::MinValue
        try { $processStartUtc = $process.StartTime.ToUniversalTime() } catch { }
        Add-TrackedProcess -ProcessId ([int]$process.Id) -ParentProcessId $PID -StartTimeUtc $processStartUtc
        $rootProcesses += [PSCustomObject]@{ Name = $item.Name; Process = $process; Path = $item.Path }
        Write-LauncherLog "Started $($item.Name): $($item.Path) (PID $($process.Id))."
        Update-TrackedProcessTree
    }

    $loginArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $loginScript + '" -RunStartedUtc "' + $runStartedUtcText + '"'
    $loginProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList $loginArguments `
        -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru
    $loginStartUtc = [DateTime]::MinValue
    try { $loginStartUtc = $loginProcess.StartTime.ToUniversalTime() } catch { }
    Add-TrackedProcess -ProcessId ([int]$loginProcess.Id) -ParentProcessId $PID -StartTimeUtc $loginStartUtc
    Write-LauncherLog "Started PokerStars login helper (PID $($loginProcess.Id))."

    while ($true) {
        Update-TrackedProcessTree

        foreach ($root in $rootProcesses) {
            $root.Process.Refresh()
            if ($root.Process.HasExited -and $root.Process.ExitCode -ne 0) {
                throw "$($root.Name) exited with code $($root.Process.ExitCode)."
            }
        }

        $loginProcess.Refresh()
        if ($loginProcess.HasExited) { break }
        Start-Sleep -Milliseconds 300
    }

    $loginProcess.Refresh()
    if ($loginProcess.ExitCode -ne 0) {
        throw "PokerStars login helper failed with exit code $($loginProcess.ExitCode). See '$((Join-Path $logDirectory 'login-error.txt'))'."
    }

    foreach ($root in $rootProcesses) {
        $root.Process.Refresh()
        if ($root.Process.HasExited -and $root.Process.ExitCode -ne 0) {
            throw "$($root.Name) exited with code $($root.Process.ExitCode)."
        }
    }

    Write-LauncherLog 'Launcher completed successfully. Applications remain running.'
    Write-Host 'PokerStars login was submitted successfully. The applications remain running.' -ForegroundColor Green
    exit 0
}
catch {
    $failureMessage = $_.Exception.Message
    Write-LauncherLog "LAUNCHER FAILURE: $failureMessage"
    Stop-LaunchedProcesses
    Write-Host ''
    Write-Host "LAUNCHER FAILED: $failureMessage" -ForegroundColor Red
    Write-Host "Processes started by this launcher were terminated. Log: $logPath" -ForegroundColor Yellow
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
