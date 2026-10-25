package cmd

import (
	"os"

	"golang.org/x/sys/unix"
)

// redirectStderr points file descriptor 2 at f, so the Go runtime's panic
// output and every direct os.Stderr write land in f.
func redirectStderr(f *os.File) error {
	return unix.Dup2(int(f.Fd()), 2)
}
