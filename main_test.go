package main

import (
	"io/fs"
	"testing"
)

func TestEmbeddedPowerShellComponents(t *testing.T) {
	required := []string{
		"scripts/setup.ps1",
		"scripts/launch.ps1",
		"scripts/ProcessJob.ps1",
		"scripts/PokerStarsLogin.ps1",
		"scripts/register.ps1",
		"scripts/uninstall.ps1",
		"assets/README.md",
		"assets/PokerStarsLauncher.ico",
	}
	for _, name := range required {
		if _, err := fs.Stat(embeddedResources, name); err != nil {
			t.Errorf("embedded resource %q is missing: %v", name, err)
		}
	}
}

func TestDefaultVersionIsSet(t *testing.T) {
	if version == "" {
		t.Fatal("application version must not be empty")
	}
}
