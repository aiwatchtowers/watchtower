//go:build linux

package cmd

import (
	"os"

	"golang.org/x/sys/unix"
)

// redirectStderr points file descriptor 2 at f, so the Go runtime's panic
// output and every direct os.Stderr write land in f. Linux uses Dup3: arm64
// and riscv64 have no dup2 system call.
func redirectStderr(f *os.File) error {
	return unix.Dup3(int(f.Fd()), 2, 0)
}
