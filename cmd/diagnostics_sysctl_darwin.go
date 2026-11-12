//go:build darwin

package cmd

import "golang.org/x/sys/unix"

// diagnosticsSysctlString reads one string sysctl key (a syscall, no
// external program) for the report's macOS and chip parts.
func diagnosticsSysctlString(name string) (string, error) { return unix.Sysctl(name) }
