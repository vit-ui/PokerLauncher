package main

import (
	"embed"
	"os"
)

// The application carries its PowerShell implementation and optional assets
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
