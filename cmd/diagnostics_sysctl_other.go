//go:build !darwin

package cmd

import "errors"

// diagnosticsSysctlString has no macOS keys to read off darwin: the report
// prints `macOS unknown` and chip `Other`.
func diagnosticsSysctlString(string) (string, error) {
	return "", errors.New("sysctl: not macOS")
}
