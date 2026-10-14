package automations

import (
	"io/fs"
	"syscall"
)

// changeTimeNanos is fi's inode change time (ctime), 0 when unavailable.
func changeTimeNanos(fi fs.FileInfo) int64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return st.Ctimespec.Nano()
	}
	return 0
}
