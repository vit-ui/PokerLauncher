package main

import (
	"embed"
	"os"
)

//go:generate go run github.com/akavel/rsrc@v0.10.2 -arch amd64 -ico assets/PokerStarsLauncher.ico -o rsrc_windows_amd64.syso

// The application carries its PowerShell implementation and assets
// inside the executable. Nothing from this directory is required at runtime
// in the user's download location.
//
//go:embed scripts assets
var embeddedResources embed.FS

// version is replaced by the release workflow at build time.
var version = "0.1.0-dev"

func main() {
	if err := run(); err != nil {
		showFatal(err)
		os.Exit(1)
	}
}
