//go:build darwin

package cmd

import (
	"golang.org/x/sys/unix"
)

// readMountTable reads the mount table once (getfsstat, MNT_NOWAIT: never
// waits on a hung network mount) — no syscall on the path asked about.
func readMountTable() ([]mountEntry, error) {
	n, err := unix.Getfsstat(nil, unix.MNT_NOWAIT)
	if err != nil {
		return nil, err //nolint:wrapcheck // the caller reports it as "mount table unreadable"
	}
	buf := make([]unix.Statfs_t, n+8) // room for a mount added in between
	n, err = unix.Getfsstat(buf, unix.MNT_NOWAIT)
	if err != nil {
		return nil, err //nolint:wrapcheck // as above
	}
	out := make([]mountEntry, 0, n)
	for _, m := range buf[:n] {
		out = append(out, mountEntry{dir: unix.ByteSliceToString(m.Mntonname[:]), local: m.Flags&unix.MNT_LOCAL != 0})
	}
	return out, nil
}
