//go:build !darwin

package sessioncleanup

import "time"

// birthTime is unknown where the filesystem keeps no birth time: the admin
// dir's mtime and ctime move with every commit in the worktree, so either
// would make an old worktree look young. Unknown keeps the worktree.
func birthTime(string) (time.Time, bool) { return time.Time{}, false }
