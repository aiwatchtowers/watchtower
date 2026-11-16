package watchman

import (
	"path/filepath"

	"watchtower/internal/fsutil"
)

// LockPath is the file every backtest holds while it runs (the CLI's and the
// daemon's weekly one), in the workspace folder.
func LockPath(workspaceDir string) string { return filepath.Join(workspaceDir, "watchman.lock") }

// Locked reports whether another holder has the lock at path right now.
func Locked(path string) bool {
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
