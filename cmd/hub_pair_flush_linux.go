package cmd

import (
	"os"

	"golang.org/x/sys/unix"
)

// flushTerminalInput drops what was typed into the terminal in but not
// read yet (tcflush(TCIFLUSH)).
func flushTerminalInput(in *os.File) {
	_ = unix.IoctlSetInt(int(in.Fd()), unix.TCFLSH, unix.TCIFLUSH)
}
