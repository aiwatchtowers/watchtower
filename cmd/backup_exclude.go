package cmd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"watchtower/internal/backupexclude"
	"watchtower/internal/config"
	"watchtower/internal/fsutil"
)

// backupExcludeApply is the seam over backupexclude.Apply; cmd tests stub it.
var backupExcludeApply = backupexclude.Apply

// backupExclusionStderr receives the failure lines (daemon.log for the
// detached daemon).
var backupExclusionStderr io.Writer = os.Stderr

// backupExclusionLogged holds the failures already logged by this process.
var (
	backupExclusionMu     sync.Mutex
	backupExclusionLogged = map[string]bool{}
)

// backupDirs lists the folders BACKUP-01 keeps out of Time Machine: the data
// root, the Desktop's Application Support folder, and a custom recordings
// folder when it lies outside the latter. ~/.config/watchtower stays in
// backups: it holds settings, no content.
func backupDirs(cfg *config.Config) []string {
	var dirs []string
	if root, err := config.DataRoot(); err == nil {
		dirs = append(dirs, root)
	}
	as, err := config.AppSupportDir()
	if err == nil {
		dirs = append(dirs, as)
	}
	rec := cfg.RecordingsDir()
	if rec == "" || (err == nil && isWithin(as, rec)) {
		return dirs
	}
	return append(dirs, rec)
}

// isWithin reports whether path is dir itself or a path inside it.
func isWithin(dir, path string) bool {
	rel, err := filepath.Rel(filepath.Clean(dir), filepath.Clean(path))
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// applyBackupExclusion keeps Watchtower's folders out of Time Machine
// (BACKUP-01). It creates the Application Support folder 0700 so a recording
// made before the daemon's first start is covered too. A failure never fails
// the caller: each one is logged once per process and the next start retries.
func applyBackupExclusion(cfg *config.Config) {
	var errs []error
	if as, err := config.AppSupportDir(); err == nil {
		if err := fsutil.MakePrivateDir(as); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", as, err))
		}
	}
	errs = append(errs, backupExcludeApply(backupDirs(cfg))...)

	backupExclusionMu.Lock()
	defer backupExclusionMu.Unlock()
	for _, err := range errs {
		msg := err.Error()
		if backupExclusionLogged[msg] {
			continue
		}
		backupExclusionLogged[msg] = true
		fmt.Fprintf(backupExclusionStderr, "backup exclusion: %s\n", msg)
	}
}
