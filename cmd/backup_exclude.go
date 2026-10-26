package cmd

import (
	"fmt"
	"io"
	"os"
	"runtime"

	"watchtower/internal/backupexclude"
	"watchtower/internal/config"
	"watchtower/internal/fsutil"
)

// backupExcludeApply is the seam over backupexclude.Apply; cmd tests stub it.
var backupExcludeApply = backupexclude.Apply

// backupExclusionStderr receives the failure lines (daemon.log for the
// detached daemon).
var backupExclusionStderr io.Writer = os.Stderr

// backupExclusionGOOS is the OS applyBackupExclusion acts for; a test seam.
var backupExclusionGOOS = runtime.GOOS

// backupDirs lists the two folders BACKUP-01 keeps out of Time Machine: the
// data root and the Desktop's Application Support folder, which holds the
// recordings. ~/.config/watchtower stays in backups.
func backupDirs() []string {
	var dirs []string
	if root, err := config.DataRoot(); err == nil {
		dirs = append(dirs, root)
	}
	if as, err := config.AppSupportDir(); err == nil {
		dirs = append(dirs, as)
	}
	return dirs
}

// applyBackupExclusion keeps Watchtower's folders out of Time Machine
// (BACKUP-01). On macOS it first creates the Application Support folder 0700,
// so a recording made before the daemon's first start is covered too. A
// failure never fails the caller: it is logged to stderr and the next start
// retries. Each process calls it once.
func applyBackupExclusion() {
	if backupExclusionGOOS != "darwin" {
		return
	}
	var errs []error
	if as, err := config.AppSupportDir(); err == nil {
		if err := fsutil.MakePrivateDir(as); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", as, err))
		}
	}
	errs = append(errs, backupExcludeApply(backupDirs())...)
	for _, err := range errs {
		fmt.Fprintf(backupExclusionStderr, "backup exclusion: %s\n", err)
	}
}
