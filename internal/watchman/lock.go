package watchman

import (
	"os"
	"path/filepath"

	"watchtower/internal/fsutil"
)

// LockPath is the workspace's Watchman lock: a backtest holds it while it
// runs (one at a time per workspace).
func LockPath(workspaceDir string) string {
	return filepath.Join(workspaceDir, "watchman.lock")
}

// Locked reports whether another holder has the lock at path right now. It
// takes the lock and releases it at once when it is free; a missing file is
// free and is not created.
func Locked(path string) bool {
	if _, err := os.Stat(path); err != nil {
		return false
	}
	unlock, ok, err := fsutil.TryLockFile(path)
	if err != nil {
		return false
	}
	if ok {
		unlock()
		return false
	}
	return true
}
