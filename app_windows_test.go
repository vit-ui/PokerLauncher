//go:build windows

package main

import (
	"strings"
	"testing"
)

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
