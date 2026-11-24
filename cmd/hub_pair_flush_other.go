//go:build !darwin && !linux

package cmd

import "os"

// flushTerminalInput is a no-op where the hub does not run.
func flushTerminalInput(*os.File) {}
