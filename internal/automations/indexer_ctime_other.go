//go:build !darwin && !linux

package automations

import "io/fs"

// changeTimeNanos is 0 where the inode change time is not read.
func changeTimeNanos(fs.FileInfo) int64 { return 0 }
