$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath)
. (Join-Path $repoRoot 'scripts\ProcessJob.ps1')
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path $repoRoot ('out\runtime-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$jobs = @()
$outsideProcess = $null
$trackedRoots = @()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        $caught = $true
    }
    Assert-True $caught "Expected failure matching '$Pattern'."
}

function Test-FixtureProcessPath {
    param([Diagnostics.Process]$Process, [string]$Directory)
    try {
        $path = $Process.MainModule.FileName
        return (-not [string]::IsNullOrEmpty($path) -and $path.StartsWith($Directory, [StringComparison]::OrdinalIgnoreCase))
    }
    catch [ComponentModel.Win32Exception] { return $false }
    catch [InvalidOperationException] { return $false }
}

function Start-UnownedTestApplication {
    param([string]$Path)
    $options = New-Object Diagnostics.ProcessStartInfo
    $options.FileName = $Path
    $options.Arguments = 'sleep'
    $options.UseShellExecute = $false
    $options.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($options)
}

function New-TestJob {
    $jobError = $null
    $job = [PokerLauncherProcessJob]::Create(('Local\PSL-test-' + [Guid]::NewGuid().ToString('N')), [ref]$jobError)
    Assert-True ($job -ne [IntPtr]::Zero) "Could not create test job: $jobError"
    $script:jobs += $job
    return $job
}

function Start-TestRoot {
    param([IntPtr]$Job, [string]$Arguments, [string]$ApplicationPath, [bool]$IsUpdater = $true)
    $childId = 0
    $handleId = 0
    $startError = $null
    $started = [PokerLauncherProcessJob]::StartProcess(
        $Job, $script:testExe, $Arguments, $testRoot, $true,
        [ref]$childId, [ref]$handleId, [ref]$startError
    )
    Assert-True $started "Could not start test root: $startError"
    $root = [PSCustomObject]@{
        Name = 'Test updater'
        ProcessId = $childId
        ProcessHandleId = $handleId
        ApplicationPath = $ApplicationPath
        IsUpdater = $IsUpdater
        ExitObservedAt = -1.0
        HandoffLogged = $false
        ApplicationProcess = $null
        ClosedNormally = $false
    }
    $script:trackedRoots += $root
    return $root
}

function Wait-TestRootExit {
    param($Root, [int]$ExpectedExitCode)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        [uint32]$code = 0
        $processError = $null
        $exited = [PokerLauncherProcessJob]::HasExited($Root.ProcessHandleId, $Root.ProcessId, [ref]$code, [ref]$processError)
        Assert-True ([string]::IsNullOrEmpty($processError)) $processError
        if ($exited) {
            Assert-True ($code -eq $ExpectedExitCode) "Unexpected root exit code $code."
            return
        }
        Start-Sleep -Milliseconds 50
    } while ($timer.Elapsed.TotalSeconds -lt 10)
    throw 'Timed out waiting for test updater to exit.'
}

try {
    # Execute the actual controller functions without starting the real apps,
    # opening UAC, or reading the user's configuration and DPAPI credentials.
    $launchPath = Join-Path $repoRoot 'scripts\launch.ps1'
    $launchSource = Get-Content -LiteralPath $launchPath -Raw
    $ast = [Management.Automation.Language.Parser]::ParseInput($launchSource, [ref]$null, [ref]$null)
    foreach ($name in @('Test-LauncherApplication', 'Write-LauncherLog')) {
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $logPath = Join-Path $testRoot 'launcher.log'

    # One executable can act as an updater, a delayed intermediate parent, or
    # a persistent app. Each descendant inherits the production Windows job.
    $testExe = Join-Path $testRoot 'PokerStars.exe'
    Add-Type -OutputAssembly $testExe -OutputType WindowsApplication -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
[assembly: System.Reflection.AssemblyProduct("PokerStars Test Fixture")]
[assembly: System.Reflection.AssemblyCompany("PokerStars Test Fixture")]
public static class PSLRuntimeFixture {
    public static int Main(string[] args) {
        string path = System.Reflection.Assembly.GetExecutingAssembly().Location;
        if (args.Length == 0) {
            if (Path.GetFileName(path) == "PokerStarsUpdate.exe") {
                Start(Path.Combine(Path.GetDirectoryName(path), "PokerStars.exe"), "sleep");
                return 0;
            }
            if (Path.GetFileName(path) == "xeester-update.exe") {
                if (Environment.GetEnvironmentVariable("PSL_TEST_FAIL_XEESTER") == "1") return 7;
                Start(Path.Combine(Path.GetDirectoryName(path), "jre", "bin", "xeester.exe"), "sleep");
                return 2;
            }
        }
        if (args.Length == 0 || args[0] == "sleep") {
            string root = Environment.GetEnvironmentVariable("PSL_TEST_CASE_ROOT");
            string name = Path.GetFileName(path);
            Stopwatch timer = Stopwatch.StartNew();
            while (timer.ElapsedMilliseconds < 60000) {
                if (!String.IsNullOrEmpty(root)) {
                    if (File.Exists(Path.Combine(root, "close0-" + name))) return 0;
                    if (File.Exists(Path.Combine(root, "close7-" + name))) return 7;
                }
                Thread.Sleep(50);
            }
            return 0;
        }
        if (args[0] == "duration") { Thread.Sleep(Int32.Parse(args[1])); return Int32.Parse(args[2]); }
        if (args[0] == "exit") return Int32.Parse(args[1]);
        if (args[0] == "handoff") {
            Start(args[1], "sleep");
            return Int32.Parse(args[2]);
        }
        if (args[0] == "delayed") {
            Start(path, "middle \"" + args[1] + "\"");
            return 2;
        }
        if (args[0] == "middle") {
            Thread.Sleep(500);
            Start(args[1], "sleep");
            return 0;
        }
        return 99;
    }
    private static void Start(string path, string args) {
        Process.Start(new ProcessStartInfo(path, args) { UseShellExecute = false, CreateNoWindow = true });
    }
}
'@
    $appExe = Join-Path $testRoot 'PSLRuntimeApp.exe'
    Copy-Item -LiteralPath $testExe -Destination $appExe

    # Exit 2 with a live owned application is a handoff, not a fatal error.
    $handoffJob = New-TestJob
    $root = Start-TestRoot $handoffJob ('handoff "' + $appExe + '" 2') $appExe
    Wait-TestRootExit $root 2
    Assert-True (Test-LauncherApplication $root $handoffJob 0) 'Updater exit 2 with an owned app must succeed.'

    # A delayed grandchild must be detected after its short-lived parent exits.
    $delayedJob = New-TestJob
    $delayed = Start-TestRoot $delayedJob ('delayed "' + $appExe + '"') $appExe
    Wait-TestRootExit $delayed 2
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    do {
        $ready = Test-LauncherApplication $delayed $delayedJob $timer.Elapsed.TotalSeconds
        if (-not $ready) { Start-Sleep -Milliseconds 50 }
    } while (-not $ready -and $timer.Elapsed.TotalSeconds -lt 10)
    Assert-True $ready 'Delayed application grandchild was not detected.'

    # Neither an unrelated process nor a same-name app in another directory
    # can hide a genuine updater failure. Zero without an app also fails.
    $outsideProcess = Start-UnownedTestApplication $appExe
    foreach ($code in @(0, 2, 7)) {
        $failedJob = New-TestJob
        $failed = Start-TestRoot $failedJob "exit $code" $appExe
        Wait-TestRootExit $failed $code
        Assert-True (-not (Test-LauncherApplication $failed $failedJob 0)) 'An unrelated app must not establish readiness.'
        Assert-Throws { Test-LauncherApplication $failed $failedJob 31 } "*exited with code $code*did not start*"
    }
    $wrongPath = Join-Path $testRoot 'other\PSLRuntimeApp.exe'
    $wrongRoot = Start-TestRoot $handoffJob 'exit 2' $wrongPath
    Wait-TestRootExit $wrongRoot 2
    Assert-True (-not (Test-LauncherApplication $wrongRoot $handoffJob 0)) 'Same-name process at a different path must not establish readiness.'
    Assert-Throws { Test-LauncherApplication $wrongRoot $handoffJob 31 } '*did not start*'
    $captionRoot = Start-TestRoot $handoffJob 'exit 7' $appExe $false
    Wait-TestRootExit $captionRoot 7
    Assert-Throws { Test-LauncherApplication $captionRoot $handoffJob 0 } '*exited with code 7*'

    # A successful handoff stays successful after a normal app close, while
    # an application crash after handoff must still fail.
    foreach ($exitCode in @(0, 7)) {
        $closeJob = New-TestJob
        $closing = Start-TestRoot $closeJob "duration 2000 $exitCode" $testExe
        Assert-True (Test-LauncherApplication $closing $closeJob 0) 'Expected to observe application startup before its close.'
        Wait-TestRootExit $closing $exitCode
        if ($exitCode -eq 0) {
            Assert-True (Test-LauncherApplication $closing $closeJob 31) 'A normal close after confirmed startup must not fail the updater handoff.'
            Assert-True $closing.ClosedNormally 'Expected a normal-close state after application exit zero.'
        }
        else { Assert-Throws { Test-LauncherApplication $closing $closeJob 31 } '*exited unexpectedly with code 7*' }
    }

    # Failed logging must not throw out of the launcher's failure cleanup.
    $logPath = $testRoot # A directory cannot be opened as a log file.
    $savedWarningPreference = $WarningPreference
    try {
        $WarningPreference = 'SilentlyContinue'
        Write-LauncherLog 'Expected logging failure in regression test.'
    }
    finally { $WarningPreference = $savedWarningPreference }
    $logPath = Join-Path $testRoot 'launcher.log'

    # Termination must include descendants and preserve the unrelated app.
    $owned = @(Get-Process -Name PSLRuntimeApp -ErrorAction SilentlyContinue | Where-Object {
        [PokerLauncherProcessJob]::IsRunningInJob($delayedJob, $_, $appExe)
    })
    Assert-True ($owned.Count -gt 0) 'Expected a live owned grandchild before cleanup.'
    $terminationError = $null
    Assert-True ([PokerLauncherProcessJob]::Terminate($delayedJob, [ref]$terminationError)) $terminationError
    foreach ($child in $owned) {
        Assert-True ($child.WaitForExit(10000)) 'Owned grandchild survived job termination.'
        $child.Dispose()
    }
    $outsideProcess.Refresh()
    Assert-True (-not $outsideProcess.HasExited) 'Cleanup terminated an unrelated process.'

    # Run the whole controller in an isolated profile with synthetic apps and
    # a login stub. Only the admin guard and real-app preflight are substituted
    # in the test copy; the shipped script has no test/elevation bypass.
    $adminDefinition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-IsAdministrator'
    }, $true)
    $testController = $launchSource.Substring(0, $adminDefinition.Extent.StartOffset) +
        'function Test-IsAdministrator { return $true }' +
        $launchSource.Substring($adminDefinition.Extent.EndOffset)
    $testController = $testController.Replace('$existingPokerStars = @(Get-Process', '$existingPokerStars = @(Microsoft.PowerShell.Management\Get-Process')
    # Restrict the preflight to fixture processes, since the machine running
    # validation may have a real PokerStars session open.
    $testController = $testController.Replace("-Name 'PokerStars' -ErrorAction SilentlyContinue)",
        "-Name 'PokerStars' -ErrorAction SilentlyContinue | Where-Object { `$_.Path -and `$_.Path.StartsWith(`$env:PSL_TEST_CASE_ROOT, [StringComparison]::OrdinalIgnoreCase) })")
    $testController = $testController.Replace('[int]$HandoffTimeoutSeconds = 30', '[int]$HandoffTimeoutSeconds = 1')
    $testController = $testController.Replace('$startupTimeoutSeconds = 240', '$startupTimeoutSeconds = 15')
    foreach ($scenario in @('success', 'already-running', 'companion-close', 'pokerstars-close', 'all-close', 'pokerstars-crash', 'start-failure', 'updater-failure', 'login-failure', 'hung-helper')) {
        $caseRoot = Join-Path $testRoot ($scenario + '-' + [char]0x00E9)
        $scriptDir = Join-Path $caseRoot 'scripts'
        $appsDir = Join-Path $caseRoot 'apps'
        $roaming = Join-Path $caseRoot 'roaming\PokerLauncher'
        New-Item -ItemType Directory -Path $scriptDir, (Join-Path $appsDir 'jre\bin'), $roaming -Force | Out-Null
        foreach ($appName in @('PokerStarsUpdate.exe', 'PokerStars.exe', 'xeester-update.exe', 'jre\bin\xeester.exe', 'StarsCaption.exe')) {
            Copy-Item -LiteralPath $testExe -Destination (Join-Path $appsDir $appName)
        }
        if ($scenario -eq 'start-failure') {
            [IO.File]::WriteAllText((Join-Path $appsDir 'StarsCaption.exe'), 'This is not a Windows executable.')
        }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\ProcessJob.ps1') -Destination $scriptDir
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Configuration.ps1') -Destination $scriptDir
        [IO.File]::WriteAllText((Join-Path $scriptDir 'launch.ps1'), $testController)
        $stub = @'
param([string]$RunStartedUtc, [string]$JobName, [string]$PokerStarsPath)
$ErrorActionPreference = 'Stop'
if (-not $RunStartedUtc -or -not $JobName -or -not $PokerStarsPath) { throw 'Missing login-helper arguments.' }
. (Join-Path $PSScriptRoot 'ProcessJob.ps1')
$job = [PokerLauncherProcessJob]::OpenForQuery($JobName)
$self = [Diagnostics.Process]::GetCurrentProcess()
try {
    if (-not [PokerLauncherProcessJob]::IsRunningInJob($job, $self, $null)) { throw 'Login helper is not in the controller job.' }
}
finally { $self.Dispose(); [PokerLauncherProcessJob]::CloseJob($job) }
if ($env:PSL_TEST_SCENARIO -in @('companion-close', 'pokerstars-close', 'all-close', 'pokerstars-crash')) {
    $log = Join-Path $env:LOCALAPPDATA 'PokerLauncher\logs\launcher.log'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (@(Select-String -LiteralPath $log -Pattern 'Confirmed application startup:').Count -lt 3) {
        if ($timer.Elapsed.TotalSeconds -gt 8) { throw 'Did not observe all fixture applications starting.' }
        Start-Sleep -Milliseconds 50
    }
    if ($env:PSL_TEST_SCENARIO -in @('companion-close', 'all-close')) {
        foreach ($name in @('xeester.exe', 'StarsCaption.exe')) {
            [IO.File]::WriteAllText((Join-Path $env:PSL_TEST_CASE_ROOT ('close0-' + $name)), '')
        }
    }
    if ($env:PSL_TEST_SCENARIO -in @('pokerstars-close', 'all-close', 'pokerstars-crash')) {
        $code = if ($env:PSL_TEST_SCENARIO -eq 'pokerstars-crash') { '7' } else { '0' }
        [IO.File]::WriteAllText((Join-Path $env:PSL_TEST_CASE_ROOT ('close' + $code + '-PokerStars.exe')), '')
        Start-Sleep -Seconds 30
    }
    Start-Sleep -Milliseconds 1500
}
if ($env:PSL_TEST_SCENARIO -eq 'hung-helper') { Start-Sleep -Seconds 30 }
if ($env:PSL_TEST_SCENARIO -eq 'login-failure') { exit 9 }
exit 0
'@
        [IO.File]::WriteAllText((Join-Path $scriptDir 'PokerStarsLogin.ps1'), $stub)
        $config = @{
            SchemaVersion = 1
            PokerStarsUsername = 'test-only'
            Applications = @{
                PokerStarsUpdater = Join-Path $appsDir 'PokerStarsUpdate.exe'
                XeesterUpdater = Join-Path $appsDir 'xeester-update.exe'
                StarsCaption = Join-Path $appsDir 'StarsCaption.exe'
            }
        }
        [IO.File]::WriteAllText((Join-Path $roaming 'config.json'), ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $testPassword = ConvertTo-SecureString 'fixture-only-password' -AsPlainText -Force
        try { ConvertFrom-SecureString $testPassword | Set-Content -LiteralPath (Join-Path $roaming 'password.dpapi') }
        finally { $testPassword.Dispose() }
        $wrapper = @'
param([string]$CaseRoot, [string]$Scenario)
$env:APPDATA = Join-Path $CaseRoot 'roaming'
$env:LOCALAPPDATA = Join-Path $CaseRoot 'local'
$env:PSL_TEST_CASE_ROOT = $CaseRoot
$env:PSL_TEST_SCENARIO = $Scenario
$env:PSL_TEST_FAIL_XEESTER = if ($Scenario -eq 'updater-failure') { '1' } else { '0' }
& (Join-Path $CaseRoot 'scripts\launch.ps1')
exit $LASTEXITCODE
'@
        $wrapperPath = Join-Path $caseRoot 'run.ps1'
        [IO.File]::WriteAllText($wrapperPath, $wrapper)
        $existingSession = $null
        if ($scenario -eq 'already-running') {
            $existingSession = Start-UnownedTestApplication (Join-Path $appsDir 'PokerStars.exe')
        }
        $output = & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapperPath -CaseRoot $caseRoot -Scenario $scenario 2>&1
        $controllerExit = $LASTEXITCODE
        $expectedExit = switch ($scenario) { { $_ -in @('success', 'already-running', 'companion-close', 'pokerstars-close', 'all-close') } { 0 }; { $_ -in @('start-failure', 'updater-failure') } { 3 }; default { 1 } }
        Assert-True ($controllerExit -eq $expectedExit) "Controller scenario '$scenario' returned $controllerExit`: $output"
        $controllerLog = Get-Content -LiteralPath (Join-Path $caseRoot 'local\PokerLauncher\logs\launcher.log') -Raw
        if ($scenario -eq 'already-running') {
            Assert-True ($controllerLog -like '*Reusing application: PokerStars*') 'Already-running session was not recorded as an expected skipped launch.'
            Assert-True ($controllerLog -notlike '*LAUNCHER FAILURE*' -and $controllerLog -notlike '*Started PokerStars login helper*' -and $controllerLog -notlike '*terminated*') 'Already-running session must skip login and failure cleanup.'
            $existingSession.Refresh()
            Assert-True (-not $existingSession.HasExited) 'The existing PokerStars session was interrupted.'
            $existingSession.Kill()
            $existingSession.WaitForExit()
            $existingSession.Dispose()
        }
        elseif ($scenario -in @('pokerstars-close', 'all-close')) {
            Assert-True ($controllerLog -like '*Launch cancelled: PokerStars closed normally*') 'Normal PokerStars close must cancel pending login automation.'
            Assert-True ($controllerLog -notlike '*LAUNCHER FAILURE*' -and $controllerLog -notlike '*terminated the entire*') 'Normal closure must not trigger a failure or terminate other applications.'
        }
        elseif ($scenario -in @('success', 'companion-close', 'start-failure', 'updater-failure')) {
            Assert-True ($controllerLog -like '*Launcher completed successfully*') "Controller did not confirm successful startup. Output: $output Log: $controllerLog"
        }
        else {
            $expectedError = switch ($scenario) {
                'start-failure' { '*Could not start StarsCaption*CreateProcess failed*' }
                'updater-failure' { '*Xeester updater exited with code 7*did not start*' }
                'login-failure' { '*login helper failed with exit code 9*' }
                'hung-helper' { '*did not complete within 15 seconds*' }
                'pokerstars-crash' { '*exited unexpectedly with code 7*' }
            }
            Assert-True ($controllerLog -like $expectedError) "Wrong controller failure for '$scenario': $controllerLog"
            Assert-True ($controllerLog -like '*Windows terminated the entire launcher process job*') 'Controller did not run failure cleanup.'
        }
        $runningFixtureCount = 0
        foreach ($fixture in @(Get-Process -Name PokerStars, xeester, StarsCaption -ErrorAction SilentlyContinue)) {
            try {
                if (-not (Test-FixtureProcessPath $fixture $appsDir)) { continue }
                if ($scenario -notin @('success', 'already-running', 'start-failure', 'updater-failure', 'companion-close', 'pokerstars-close')) { throw "Fixture PID $($fixture.Id) survived failed controller cleanup." }
                $runningFixtureCount++
                $fixture.Kill()
                $fixture.WaitForExit()
            }
            finally { $fixture.Dispose() }
        }
        if ($scenario -in @('success', 'already-running', 'start-failure', 'updater-failure', 'companion-close', 'pokerstars-close', 'all-close')) {
            $expectedRunning = switch ($scenario) { 'success' { 3 }; 'already-running' { 2 }; 'start-failure' { 2 }; 'updater-failure' { 2 }; 'companion-close' { 1 }; 'pokerstars-close' { 2 }; 'all-close' { 0 } }
            Assert-True ($runningFixtureCount -eq $expectedRunning) "Scenario '$scenario' left $runningFixtureCount apps running, expected $expectedRunning."
        }
    }

    # Exercise the deferred uninstall script through powershell.exe -File,
    # where a [bool] parameter cannot bind the strings True/False in PS 5.1.
    $uninstallAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot 'scripts\uninstall.ps1'), [ref]$null, [ref]$null)
    $assignment = $uninstallAst.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$cleanupScript'
    }, $true)
    $cleanupSource = $assignment.Right.Expression.Value
    foreach ($remove in @('True', 'False')) {
        $caseRoot = Join-Path $testRoot ('uninstall-' + $remove)
        $app = Join-Path $caseRoot 'application'
        $roaming = Join-Path $caseRoot 'roaming'
        $local = Join-Path $caseRoot 'local'
        New-Item -ItemType Directory -Path $app, $roaming, $local -Force | Out-Null
        $cleanupFile = Join-Path $caseRoot 'cleanup.ps1'
        [IO.File]::WriteAllText($cleanupFile, $cleanupSource)
        & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cleanupFile -ParentProcessId 0 -ApplicationDirectory $app -AppDataDirectory $roaming -LocalDataDirectory $local -RemoveUserData $remove -SelfPath $cleanupFile
        Assert-True ($LASTEXITCODE -eq 0) "Deferred uninstall failed for RemoveUserData=$remove."
        Assert-True (-not (Test-Path -LiteralPath $app)) 'Uninstall left application files behind.'
        Assert-True ((Test-Path -LiteralPath $roaming) -eq ($remove -eq 'False')) 'Uninstall roaming-data choice was not honored.'
        Assert-True ((Test-Path -LiteralPath $local) -eq ($remove -eq 'False')) 'Uninstall local-data choice was not honored.'
        Assert-True (-not (Test-Path -LiteralPath $cleanupFile)) 'Deferred uninstall did not remove itself.'
    }

    Write-Host 'Passed Windows runtime regressions: updater handoffs, genuine failures, delayed grandchildren, job/path isolation, failure cleanup, logging failures, complete controller success/failure/timeout scenarios, and both uninstall data choices.'
}
finally {
    foreach ($root in $trackedRoots) {
        if ($null -ne $root.ApplicationProcess) { $root.ApplicationProcess.Dispose() }
    }
    foreach ($job in $jobs) {
        $ignored = $null
        [void][PokerLauncherProcessJob]::Terminate($job, [ref]$ignored)
        [PokerLauncherProcessJob]::CloseJob($job)
    }
    [PokerLauncherProcessJob]::CloseProcessHandles()
    if ($null -ne $outsideProcess) {
        if (-not $outsideProcess.HasExited) { $outsideProcess.Kill(); $outsideProcess.WaitForExit() }
        $outsideProcess.Dispose()
    }
    foreach ($fixture in @(Get-Process -Name PokerStarsUpdate, PokerStars, xeester-update, xeester, StarsCaption -ErrorAction SilentlyContinue)) {
        try {
            if (Test-FixtureProcessPath $fixture $testRoot) {
                $fixture.Kill()
                $fixture.WaitForExit()
            }
        }
        finally { $fixture.Dispose() }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
