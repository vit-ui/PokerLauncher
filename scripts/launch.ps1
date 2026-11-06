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

# The Go application requests UAC before invoking this controller. Keeping
# elevation here as well would create a second controller and break its error
# reporting, so fail explicitly if the token is not elevated.
if (-not (Test-IsAdministrator)) {
    throw 'The launcher controller must be started with administrator privileges.'
}

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

# A Windows Job Object gives this invocation process-tree ownership. Processes
# are created suspended, assigned to the job, and only then resumed. Therefore
# descendants inherit job membership from the start, without polling WMI and
# risking a missed short-lived parent process. On failure, TerminateJobObject
# terminates all processes in this invocation while leaving unrelated apps
# (including sessions that were already running) untouched.
if (-not ('PokerStarsLauncherProcessJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class PokerStarsLauncherProcessJob {
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint STARTF_USESHOWWINDOW = 0x00000001;
    private const ushort SW_HIDE = 0;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint INFINITE = 0xFFFFFFFF;

    private static readonly Dictionary<int, IntPtr> ProcessHandles = new Dictionary<int, IntPtr>();
    private static int NextProcessHandleId = 0;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static string LastError() {
        return new Win32Exception(Marshal.GetLastWin32Error()).Message;
    }

    public static IntPtr Create(out string error) {
        error = null;
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) error = "CreateJobObject failed: " + LastError();
        return job;
    }

    public static bool StartProcess(IntPtr job, string applicationPath, string arguments,
                                    string workingDirectory, bool hidden,
                                    out int processId, out int processHandleId, out string error) {
        processId = 0;
        processHandleId = 0;
        error = null;
        if (job == IntPtr.Zero) {
            error = "The process job handle is not available.";
            return false;
        }

        STARTUPINFO startup = new STARTUPINFO();
        startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        if (hidden) {
            startup.dwFlags = STARTF_USESHOWWINDOW;
            startup.wShowWindow = SW_HIDE;
        }

        string command = "\"" + applicationPath + "\"";
        if (!String.IsNullOrWhiteSpace(arguments)) command += " " + arguments;
        StringBuilder mutableCommand = new StringBuilder(command);
        PROCESS_INFORMATION info;

        bool created = CreateProcess(
            applicationPath, mutableCommand, IntPtr.Zero, IntPtr.Zero, false,
            CREATE_SUSPENDED, IntPtr.Zero, workingDirectory, ref startup, out info);
        if (!created) {
            error = "CreateProcess failed for '" + applicationPath + "': " + LastError();
            return false;
        }

        bool resumed = false;
        try {
            if (!AssignProcessToJobObject(job, info.hProcess)) {
                error = "Could not assign '" + applicationPath + "' to the launcher process job: " + LastError();
                return false;
            }

            uint previousSuspendCount = ResumeThread(info.hThread);
            if (previousSuspendCount == 0xFFFFFFFF) {
                error = "Could not resume '" + applicationPath + "': " + LastError();
                return false;
            }

            lock (ProcessHandles) {
                NextProcessHandleId++;
                if (NextProcessHandleId <= 0) NextProcessHandleId = 1;
                while (ProcessHandles.ContainsKey(NextProcessHandleId)) {
                    NextProcessHandleId++;
                    if (NextProcessHandleId <= 0) NextProcessHandleId = 1;
                }
                processHandleId = NextProcessHandleId;
                ProcessHandles.Add(processHandleId, info.hProcess);
            }
            processId = (int)info.dwProcessId;
            resumed = true;
            return true;
        }
        finally {
            if (!resumed) TerminateProcess(info.hProcess, 1);
            CloseHandle(info.hThread);
            if (!resumed) CloseHandle(info.hProcess);
        }
    }

    // Returns true only after the process handle is signaled. Exit code is
    // read from the retained handle, so an immediately-exiting updater is
    // still observed reliably even if its PID is reused later.
    public static bool HasExited(int processHandleId, int processId, out uint exitCode, out string error) {
        exitCode = 0;
        error = null;
        IntPtr process;
        lock (ProcessHandles) {
            if (!ProcessHandles.TryGetValue(processHandleId, out process)) {
                error = "No retained process handle exists for process handle ID " + processHandleId + " (PID " + processId + ").";
                return false;
            }
        }

        uint wait = WaitForSingleObject(process, 0);
        if (wait == WAIT_TIMEOUT) return false;
        if (wait != WAIT_OBJECT_0) {
            error = "WaitForSingleObject failed for PID " + processId + ": " + LastError();
            return false;
        }
        if (!GetExitCodeProcess(process, out exitCode)) {
            error = "GetExitCodeProcess failed for PID " + processId + ": " + LastError();
            return false;
        }
        return true;
    }

    public static bool Terminate(IntPtr job, out string error) {
        error = null;
        if (job == IntPtr.Zero) return true;
        if (!TerminateJobObject(job, 1)) {
            error = "TerminateJobObject failed: " + LastError();
            return false;
        }
        return true;
    }

    public static void CloseJob(IntPtr job) {
        if (job != IntPtr.Zero) CloseHandle(job);
    }

    public static void CloseProcessHandles() {
        lock (ProcessHandles) {
            foreach (IntPtr process in ProcessHandles.Values) CloseHandle(process);
            ProcessHandles.Clear();
        }
    }
}
'@
}

$jobHandle = [IntPtr]::Zero
$rootProcesses = @()
$loginProcessId = 0
$failureMessage = $null
$runStartedUtc = [DateTime]::UtcNow
$runStartedUtcText = $runStartedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Configuration not found: $configPath. Run Configure PokerStarsLauncher from the Start Menu first."
    }
    if (-not (Test-Path -LiteralPath $loginScript -PathType Leaf)) {
        throw "PokerStars login helper not found: $loginScript"
    }
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell executable was not found: $windowsPowerShell"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ([int]$config.SchemaVersion -ne 1) {
        throw 'Unsupported configuration schema. Run Configure PokerStarsLauncher from the Start Menu again.'
    }

    $launchItems = @(
        [PSCustomObject]@{ Name = 'PokerStars updater'; Path = [string]$config.Applications.PokerStarsUpdater },
        [PSCustomObject]@{ Name = 'Xeester updater'; Path = [string]$config.Applications.XeesterUpdater },
        [PSCustomObject]@{ Name = 'StarsCaption'; Path = [string]$config.Applications.StarsCaption }
    )

    foreach ($item in $launchItems) {
        if ([string]::IsNullOrWhiteSpace($item.Path) -or -not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            throw "Configured executable for $($item.Name) was not found: $($item.Path). Run Configure PokerStarsLauncher from the Start Menu to correct it."
        }
    }

    # The login helper intentionally targets only a PokerStars process created
    # during this launcher invocation. Refuse to start if an older PokerStars
    # process is still present, instead of waiting 180 seconds for a dialog in
    # a process the launcher does not own.
    $existingPokerStars = @(Get-Process -Name 'PokerStars' -ErrorAction SilentlyContinue)
    if ($existingPokerStars.Count -gt 0) {
        throw 'PokerStars is already running. Close every PokerStars window and process, then run the launcher again.'
    }

    $nativeError = $null
    $jobHandle = [PokerStarsLauncherProcessJob]::Create([ref]$nativeError)
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
        }
        Write-LauncherLog "Started $($item.Name): $($item.Path) (PID $processId)."
    }

    $loginArguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $loginScript + '" -RunStartedUtc "' + $runStartedUtcText + '"'
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
        foreach ($root in $rootProcesses) {
            [uint32]$rootExitCode = 0
            $rootError = $null
            $rootExited = [PokerStarsLauncherProcessJob]::HasExited(
                [int]$root.ProcessHandleId, [int]$root.ProcessId, [ref]$rootExitCode, [ref]$rootError
            )
            if (-not [string]::IsNullOrWhiteSpace($rootError)) { throw $rootError }
            if ($rootExited -and $rootExitCode -ne 0) {
                throw "$($root.Name) exited with code $rootExitCode."
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
            break
        }
        Start-Sleep -Milliseconds 300
    }

    foreach ($root in $rootProcesses) {
        [uint32]$rootExitCode = 0
        $rootError = $null
        $rootExited = [PokerStarsLauncherProcessJob]::HasExited(
            [int]$root.ProcessHandleId, [int]$root.ProcessId, [ref]$rootExitCode, [ref]$rootError
        )
        if (-not [string]::IsNullOrWhiteSpace($rootError)) { throw $rootError }
        if ($rootExited -and $rootExitCode -ne 0) {
            throw "$($root.Name) exited with code $rootExitCode."
        }
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
