//go:build unix

package db

import (
	"fmt"
	"syscall"
)

// statfsFreeBytes is freeDiskBytes's production statfs: the blocks available
// to an unprivileged writer times the block size.
func statfsFreeBytes(dir string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, fmt.Errorf("statfs %s: %w", dir, err)
	}
	// Bsize is uint32 on darwin and int64 on linux; uint64 fits both.
	return int64(st.Bavail * uint64(st.Bsize)), nil
}
