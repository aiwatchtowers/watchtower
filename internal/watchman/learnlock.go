package watchman

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"watchtower/internal/fsutil"
)

// LearnLockPath is the lock one learner holds while it learns a workbench:
// <workspace>/watchman/learn-<workbench>.lock (spec 2026-11-21 §3).
func LearnLockPath(workspaceDir string, workbenchID int64) string {
	return filepath.Join(workspaceDir, "watchman", "learn-"+strconv.FormatInt(workbenchID, 10)+".lock")
}

// TryLearnLock takes the workbench's learn lock without waiting: the
// daemon's learner and `watchman learn --start` learn one workbench one at
// a time, and the one that finds the lock held skips (ok false, no error).
// unlock releases it.
func TryLearnLock(workspaceDir string, workbenchID int64) (unlock func(), ok bool, err error) {
	path := LearnLockPath(workspaceDir, workbenchID)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, false, fmt.Errorf("watchman learn lock: %w", err)
	}
	return fsutil.TryLockFile(path)
}
