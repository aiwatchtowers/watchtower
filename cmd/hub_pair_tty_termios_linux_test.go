package cmd

import "golang.org/x/sys/unix"

// The termios get and set requests (tcgetattr/tcsetattr).
const (
	ioctlGetTermios = unix.TCGETS
	ioctlSetTermios = unix.TCSETS
)
