//go:build !windows

package main

import (
	"fmt"
	"os"
)

func run() error {
	return fmt.Errorf("PokerStarsLauncher is a Windows application")
}

func showFatal(err error) { fmt.Fprintln(os.Stderr, err) }
