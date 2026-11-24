package cmd

import (
	"os"

	"golang.org/x/sys/unix"
)

// flushTerminalInput drops what was typed into the terminal in but not
// read yet (tcflush(TCIFLUSH): TIOCFLUSH with FREAD, which is 1 on darwin).
func flushTerminalInput(in *os.File) {
	_ = unix.IoctlSetPointerInt(int(in.Fd()), unix.TIOCFLUSH, 1)
}
