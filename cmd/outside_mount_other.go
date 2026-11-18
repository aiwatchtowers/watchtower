//go:build !darwin

package cmd

import "errors"

// readMountTable has no mount table to read off macOS: the outside-bench
// hook then walks nothing (spec 2026-11-18 §6.7 is macOS only).
func readMountTable() ([]mountEntry, error) {
	return nil, errors.New("no mount table on this platform")
}
