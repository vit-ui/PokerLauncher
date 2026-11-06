//go:build windows

package main

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallAndUpdateExtractCurrentPackageAndPreserveUserData(t *testing.T) {
	profile := filepath.Join(t.TempDir(), "profile")
	t.Setenv("APPDATA", profile)
	userData := filepath.Join(profile, "PokerStarsLauncher")
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
			gotExe, err := os.ReadFile(filepath.Join(installDir, "PokerStarsLauncher.exe"))
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
		for _, path := range []string{"scripts/ProcessJob.ps1", "PokerStarsLauncher.exe", "version.txt"} {
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
