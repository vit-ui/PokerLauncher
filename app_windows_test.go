//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestAlreadyRunningDialogExplainsNextStepWithoutOldFailures(t *testing.T) {
	t.Setenv("LOCALAPPDATA", t.TempDir())
	logDir := filepath.Join(os.Getenv("LOCALAPPDATA"), "PokerLauncher", "logs")
	if err := os.MkdirAll(logDir, 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"launcher.log", "login-error.txt"} {
		if err := os.WriteFile(filepath.Join(logDir, name), []byte("OLD LAUNCHER FAILURE: previous updater error"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	title, message, flags := launchErrorDialog(fmt.Errorf("controller: %w", errPokerStarsAlreadyRunning))
	if title != "PokerStars is already running" || flags != mbOK|mbIconInformation {
		t.Fatalf("expected an informational already-running dialog, got %q, flags %#x", title, flags)
	}
	for _, required := range []string{"Close PokerStars", "open PokerLauncher again", "current session has been left running"} {
		if !strings.Contains(message, required) {
			t.Errorf("dialog is missing %q: %s", required, message)
		}
	}
	for _, unwanted := range []string{"OLD", "FAILURE", "launcher.log", "exit status", "line 133"} {
		if strings.Contains(message, unwanted) {
			t.Errorf("already-running dialog includes irrelevant diagnostics %q", unwanted)
		}
	}
	_, failureMessage, failureFlags := launchErrorDialog(errors.New("real startup failure"))
	if failureFlags != mbOK|mbIconError || strings.Contains(failureMessage, "real startup failure") {
		t.Fatal("genuine errors must use a concise failure dialog without raw technical output")
	}
}

func TestFailureDialogsAreShortAndKeepDiagnosticsInLog(t *testing.T) {
	t.Setenv("LOCALAPPDATA", t.TempDir())
	cases := []struct{ detail, want string }{
		{"launch.ps1 failed: exit status 1\nLAUNCHER FAILED: Xeester updater exited with code 2, but C:\\Xeester\\jre\\bin\\xeester.exe did not start. (launch.ps1 line 53)", "Xeester could not finish starting"},
		{"PokerStars login helper failed with exit code 1. See C:\\logs\\login-error.txt", "PokerStars login could not be completed"},
		{"The saved password cannot be decrypted. (launch.ps1 line 110)", "saved launcher settings need attention"},
		{"Application 'C:\\PokerStars\\PokerStars.exe' exited unexpectedly with code 7.", "PokerStars could not finish starting"},
		{"Application startup did not complete within 240 seconds.", "took too long"},
		{"installing PokerLauncher.exe: Access denied", "update could not be installed"},
		{"refreshing application shortcuts and uninstall registration: register.ps1 failed: exit status 1", "shortcuts and Windows Apps entry"},
		{"Unknown native exception at launch.ps1 line 133", "could not complete startup"},
	}
	for _, item := range cases {
		message := formatLaunchError(errors.New(item.detail))
		if !strings.Contains(message, item.want) || len(message) > 400 || strings.Count(message, "\n") > 4 {
			t.Errorf("unexpected failure message: %q", message)
		}
		for _, technical := range []string{"exit status", ".ps1", "C:\\", "LAUNCHER FAILED", "line 133"} {
			if strings.Contains(message, technical) {
				t.Errorf("dialog leaked technical detail %q: %s", technical, message)
			}
		}
		logApplicationError(errors.New(item.detail))
	}
	diagnostic, err := os.ReadFile(filepath.Join(os.Getenv("LOCALAPPDATA"), "PokerLauncher", "logs", "application.log"))
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range cases {
		if !strings.Contains(string(diagnostic), item.detail) {
			t.Errorf("full diagnostic was not saved: %s", item.detail)
		}
	}
}

func TestUpgradeRefreshesRegistrationWithoutUninstall(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())
	t.Setenv("LOCALAPPDATA", t.TempDir())
	installDir := filepath.Join(t.TempDir(), "installed app é")
	if err := os.MkdirAll(installDir, 0755); err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string]string{"PokerLauncher.exe": "old executable", "version.txt": "1.0.2"} {
		if err := os.WriteFile(filepath.Join(installDir, name), []byte(data), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := installOrUpdate(installDir); err != nil {
		t.Fatal(err)
	}
	proofName := "upgrade-location-proof.txt"
	if err := os.WriteFile(filepath.Join(installDir, proofName), []byte("upgrade fixture"), 0644); err != nil {
		t.Fatal(err)
	}
	source, err := embeddedResources.ReadFile("scripts/register.ps1")
	if err != nil {
		t.Fatal(err)
	}
	literal := func(value string) string { return "'" + strings.ReplaceAll(value, "'", "''") + "'" }
	testID := t.TempDir()
	testRegistry := `HKCU:\Software\PokerLauncherTests\` + filepath.Base(filepath.Dir(testID)) + "-" + filepath.Base(testID)
	desktop := filepath.Join(installDir, "test desktop")
	programs := filepath.Join(installDir, "test programs")
	if err := os.MkdirAll(desktop, 0755); err != nil {
		t.Fatal(err)
	}
	registration := string(source)
	registration = strings.ReplaceAll(registration, `'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PokerLauncher'`, literal(testRegistry))
	registration = strings.ReplaceAll(registration, `'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PokerStarsLauncher'`, literal(testRegistry+"-legacy"))
	registration = strings.ReplaceAll(registration, `[Environment]::GetFolderPath('DesktopDirectory')`, literal(desktop))
	registration = strings.ReplaceAll(registration, `[Environment]::GetFolderPath('Programs')`, literal(programs))
	// Execute the real registration logic in an isolated registry key and
	// temporary shortcut folders, including an older installed version.
	wrapper := "$ErrorActionPreference = 'Stop'\r\n$testRegistry = " + literal(testRegistry) + `
try {
    New-Item -Path $testRegistry -Force | Out-Null
    New-ItemProperty -Path $testRegistry -Name DisplayVersion -Value '1.0.2' -Force | Out-Null
` + registration + "\r\n" + `
    $entry = Get-ItemProperty -LiteralPath $testRegistry
    if ($entry.DisplayVersion -ne ` + literal(version) + `) { throw 'Windows Apps kept the old version.' }
    if (-not (Test-Path -LiteralPath (Join-Path $entry.InstallLocation ` + literal(proofName) + `) -PathType Leaf)) { throw "Incorrect installation registration: $($entry.InstallLocation)" }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut(` + literal(filepath.Join(desktop, "PokerLauncher.lnk")) + `)
    if ([IO.Path]::GetFileName($shortcut.TargetPath) -ne 'PokerLauncher.exe' -or
        -not (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($shortcut.TargetPath)) ` + literal(proofName) + `) -PathType Leaf) -or
        $shortcut.Arguments -ne '--launch') { throw "The launch shortcut was not refreshed: $($shortcut.TargetPath)" }
}
finally { Remove-Item -LiteralPath $testRegistry -Recurse -Force -ErrorAction SilentlyContinue }
`
	data := append([]byte{0xef, 0xbb, 0xbf}, []byte(wrapper)...)
	if err := os.WriteFile(filepath.Join(installDir, "scripts", "register.ps1"), data, 0644); err != nil {
		t.Fatal(err)
	}
	if err := runPowerShellInDirectory(installDir, "register.ps1"); err != nil {
		t.Fatal(err)
	}
}

func TestPowerShellExitStatusDistinguishesAlreadyRunningFromFailures(t *testing.T) {
	powerShell := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	for _, code := range []string{"1", "2"} {
		command := exec.Command(powerShell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "exit "+code)
		command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow, HideWindow: true}
		processError := command.Run()
		if processError == nil {
			t.Fatal("expected a nonzero PowerShell exit status")
		}
		for _, script := range []string{"launch.ps1", "setup.ps1", "uninstall.ps1"} {
			err := powerShellResultError(script, []byte("diagnostic output"), processError)
			if got, want := errors.Is(err, errPokerStarsAlreadyRunning), script == "launch.ps1" && code == "2"; got != want {
				t.Errorf("%s exit %s: already-running classification = %v, want %v", script, code, got, want)
			}
		}
	}
}

func TestInstallAndUpdateExtractCurrentPackageAndPreserveUserData(t *testing.T) {
	profile := filepath.Join(t.TempDir(), "profile")
	t.Setenv("APPDATA", profile)
	userData := filepath.Join(profile, "PokerLauncher")
	if err := os.MkdirAll(userData, 0755); err != nil {
		t.Fatal(err)
	}
	saved := map[string][]byte{
		"config.json":    []byte(`{"SchemaVersion":1,"PokerStarsUsername":"preserve-me"}`),
		"password.dpapi": []byte("existing-encrypted-password"),
	}
	for name, data := range saved {
		if err := os.WriteFile(filepath.Join(userData, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}

	installDir := filepath.Join(t.TempDir(), "installed app é")
	for _, stage := range []string{"install", "update"} {
		t.Run(stage, func(t *testing.T) {
			if err := installOrUpdate(installDir); err != nil {
				t.Fatal(err)
			}
			if err := fs.WalkDir(embeddedResources, ".", func(path string, entry fs.DirEntry, err error) error {
				if err != nil || entry.IsDir() {
					return err
				}
				want, err := embeddedResources.ReadFile(path)
				if err != nil {
					return err
				}
				got, err := os.ReadFile(filepath.Join(installDir, filepath.FromSlash(path)))
				if err != nil {
					return err
				}
				if !bytes.Equal(got, want) {
					t.Errorf("installed resource %s does not match this package", path)
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			source, err := os.Executable()
			if err != nil {
				t.Fatal(err)
			}
			wantExe, err := os.ReadFile(source)
			if err != nil {
				t.Fatal(err)
			}
			gotExe, err := os.ReadFile(filepath.Join(installDir, "PokerLauncher.exe"))
			if err != nil || !bytes.Equal(gotExe, wantExe) {
				t.Fatalf("installed executable does not match the running package: %v", err)
			}
			gotVersion, err := os.ReadFile(filepath.Join(installDir, "version.txt"))
			if err != nil || strings.TrimSpace(string(gotVersion)) != version {
				t.Fatalf("installed version is incorrect: %q, %v", gotVersion, err)
			}
			for name, want := range saved {
				got, err := os.ReadFile(filepath.Join(userData, name))
				if err != nil || !bytes.Equal(got, want) {
					t.Errorf("%s modified user data %s: %v", stage, name, err)
				}
			}
		})
		// The next installation must repair a stale script and replace an old EXE.
		for _, path := range []string{"scripts/ProcessJob.ps1", "PokerLauncher.exe", "version.txt"} {
			if err := os.WriteFile(filepath.Join(installDir, filepath.FromSlash(path)), []byte("old version"), 0644); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestInteractivePowerShellScriptsHaveNoConsoleAndKeepDialogsVisible(t *testing.T) {
	for _, script := range []string{"setup.ps1", "uninstall.ps1"} {
		t.Run(script, func(t *testing.T) {
			args, attributes := powerShellProcessOptions(script, `C:\\App\\scripts\\`+script)
			if attributes == nil {
				t.Fatal("expected Windows process attributes")
			}
			if attributes.CreationFlags&createNoWindow == 0 {
				t.Fatal("interactive PowerShell must use CREATE_NO_WINDOW to suppress its console")
			}
			if attributes.HideWindow {
				t.Fatal("interactive PowerShell must not use HideWindow because that can hide its Windows Forms dialog")
			}
			if strings.Contains(strings.Join(args, " "), "-WindowStyle Hidden") {
				t.Fatal("interactive PowerShell must not request a hidden window")
			}
			if args[len(args)-2] != "-File" || !strings.HasSuffix(args[len(args)-1], script) {
				t.Fatalf("unexpected PowerShell arguments: %#v", args)
			}
		})
	}
}

func TestBackgroundPowerShellScriptsRemainHidden(t *testing.T) {
	args, attributes := powerShellProcessOptions("launch.ps1", `C:\\App\\scripts\\launch.ps1`)
	if attributes == nil || !attributes.HideWindow {
		t.Fatal("background PowerShell must use HideWindow")
	}
	if attributes.CreationFlags&createNoWindow == 0 {
		t.Fatal("background PowerShell must use CREATE_NO_WINDOW")
	}
	if !strings.Contains(strings.Join(args, " "), "-WindowStyle Hidden") {
		t.Fatal("background PowerShell must request a hidden window")
	}
}

func TestMigrationFailureAllowsSettingsRecovery(t *testing.T) {
	for _, credential := range []string{"missing", "invalid"} {
		for _, action := range []string{"cancel", "manual", "password"} {
			t.Run(credential+"/"+action, func(t *testing.T) {
				t.Setenv("APPDATA", t.TempDir())
				t.Setenv("LOCALAPPDATA", t.TempDir())
				t.Setenv("POKERLAUNCHER_TEST_RECOVERY", action)
				legacy := filepath.Join(os.Getenv("APPDATA"), "PokerStarsLauncher")
				if err := os.MkdirAll(legacy, 0755); err != nil {
					t.Fatal(err)
				}
				original := []byte(`{"SchemaVersion":1,"PokerStarsUsername":"recover-me","Applications":{"PokerStarsUpdater":"C:\\PokerStars\\PokerStarsUpdate.exe","XeesterUpdater":"C:\\Xeester\\update.exe","StarsCaption":"C:\\Caption\\caption.exe"}}`)
				legacyConfig := filepath.Join(legacy, "config.json")
				if err := os.WriteFile(legacyConfig, original, 0600); err != nil {
					t.Fatal(err)
				}
				legacyPassword := filepath.Join(legacy, "password.dpapi")
				if credential == "invalid" {
					if err := os.WriteFile(legacyPassword, []byte("undecryptable"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				directory := t.TempDir()
				scripts := filepath.Join(directory, "scripts")
				if err := os.MkdirAll(scripts, 0755); err != nil {
					t.Fatal(err)
				}
				for _, name := range []string{"Configuration.ps1", "migrate.ps1"} {
					data, err := embeddedResources.ReadFile("scripts/" + name)
					if err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(filepath.Join(scripts, name), data, 0600); err != nil {
						t.Fatal(err)
					}
				}
				// Exercise real migration and routing with noninteractive stand-ins
				// for the settings dialog and registration. No real registry writes.
				setup := `
$ErrorActionPreference = 'Stop'
if ($env:POKERLAUNCHER_TEST_RECOVERY -eq 'cancel') { exit 0 }
. (Join-Path $PSScriptRoot 'Configuration.ps1')
$config = Read-LauncherConfiguration (Join-Path $env:APPDATA 'PokerStarsLauncher\config.json')
$destination = Join-Path $env:APPDATA 'PokerLauncher'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
if ($env:POKERLAUNCHER_TEST_RECOVERY -eq 'manual') { $config.LoginMode = 'Manual' }
else {
    $password = ConvertTo-SecureString 'replacement-fixture-password' -AsPlainText -Force
    try {
        $path = Join-Path $destination 'password.dpapi'
        [IO.File]::WriteAllText($path, (ConvertFrom-SecureString $password))
        $verified = ConvertTo-SecureString ([IO.File]::ReadAllText($path))
        try { if ($verified.Length -ne $password.Length) { throw 'Replacement password failed verification.' } }
        finally { $verified.Dispose() }
    } finally { $password.Dispose() }
}
Write-LauncherConfiguration $config (Join-Path $destination 'config.json')
`
				registration := `[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'registered.txt'), 'registered')`
				for name, data := range map[string]string{"setup.ps1": setup, "register.ps1": registration} {
					if err := os.WriteFile(filepath.Join(scripts, name), []byte(data), 0600); err != nil {
						t.Fatal(err)
					}
				}
				recovery, err := prepareInstalledSettings(directory)
				if err != nil || !recovery {
					t.Fatalf("migration failure must request Settings: recovery=%v err=%v", recovery, err)
				}
				marker := filepath.Join(scripts, "registered.txt")
				if _, err := os.Stat(marker); !os.IsNotExist(err) {
					t.Fatal("failed migration must defer registration")
				}
				if configExists() {
					t.Fatal("failed migration published a configuration")
				}
				if err := runSetupInDirectory(directory); err != nil {
					t.Fatal(err)
				}
				got, err := os.ReadFile(legacyConfig)
				if err != nil || !bytes.Equal(got, original) {
					t.Fatal("recovery modified legacy configuration")
				}
				saved, err := os.ReadFile(legacyPassword)
				if credential == "missing" {
					if !os.IsNotExist(err) {
						t.Fatal("recovery created a legacy credential")
					}
				} else if err != nil || string(saved) != "undecryptable" {
					t.Fatal("recovery modified legacy credential")
				}
				if action == "cancel" {
					if configExists() {
						t.Fatal("cancelled recovery saved settings")
					}
					if _, err := os.Stat(marker); !os.IsNotExist(err) {
						t.Fatal("cancelled recovery registered the new app")
					}
					return
				}
				if _, err := os.Stat(marker); err != nil {
					t.Fatal("saved recovery did not refresh registration", err)
				}
				data, err := os.ReadFile(filepath.Join(os.Getenv("APPDATA"), "PokerLauncher", "config.json"))
				if err != nil {
					t.Fatal(err)
				}
				var config struct {
					LoginMode, PokerStarsUsername string
					Helpers                       []json.RawMessage
				}
				if err := json.Unmarshal(data, &config); err != nil {
					t.Fatal(err)
				}
				expected := "PokerStars"
				if action == "manual" {
					expected = "Manual"
				}
				if config.LoginMode != expected || config.PokerStarsUsername != "recover-me" || len(config.Helpers) != 2 {
					t.Fatalf("recovery lost settings: %+v", config)
				}
				recovery, err = prepareInstalledSettings(directory)
				if err != nil || recovery {
					t.Fatalf("saved recovery must bypass legacy migration: %v %v", recovery, err)
				}
			})
		}
	}
}
