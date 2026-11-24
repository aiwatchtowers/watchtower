//go:build !darwin && !linux

package cmd

import (
	"errors"
	"os"
)

// flushTerminalInput cannot drop typed-ahead input where the hub does not
// run: it fails, so `hub pair` takes no typed answer there.
func flushTerminalInput(*os.File) error {
	return errors.New("flushing terminal input is not supported on this platform")
}
