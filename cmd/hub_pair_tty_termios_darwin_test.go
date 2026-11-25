package cmd

import "golang.org/x/sys/unix"

// The termios get and set requests (tcgetattr/tcsetattr).
const (
	ioctlGetTermios = unix.TIOCGETA
	ioctlSetTermios = unix.TIOCSETA
)
