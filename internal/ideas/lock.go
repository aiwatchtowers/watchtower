package ideas

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// backfillLockFilename is the cross-process backfill lock — a plain file
// (not flock, unlike internal/memory/vault.go's Lock): AcquireBackfillLock's
// writer and BackfillLockFresh's reader run in different processes (a CLI
// `ideas mine --from` invocation and the long-lived daemon), and the daemon
// side only ever needs a cheap read, never to contend for the lock itself.
const backfillLockFilename = "ideas_backfill.lock"

// backfillLockFreshWindow is how long a lock file is honored before it is
// treated as stale (a crashed backfill that never removed its own lock) —
// spec §5.
const backfillLockFreshWindow = 2 * time.Hour

// AcquireBackfillLock takes the ideas backfill lock in workspaceDir: it
// writes ideas_backfill.lock (contents "pid=<n> started=<RFC3339>") and
// returns a release func that removes it. Errors if a lock less than
// backfillLockFreshWindow old already exists — another backfill is in
// progress. A stale lock (older, or one BackfillLockFresh cannot make sense
// of) is overwritten rather than blocking forever on a crashed run.
func AcquireBackfillLock(workspaceDir string) (release func(), err error) {
	path := filepath.Join(workspaceDir, backfillLockFilename)
	if BackfillLockFresh(workspaceDir) {
		return nil, fmt.Errorf("ideas: a backfill is already in progress (%s)", path)
	}
	contents := fmt.Sprintf("pid=%d started=%s\n", os.Getpid(), time.Now().UTC().Format(time.RFC3339))
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		return nil, fmt.Errorf("ideas: writing backfill lock: %w", err)
	}
	return func() {
		_ = os.Remove(path)
	}, nil
}

// BackfillLockFresh reports whether workspaceDir holds a backfill lock less
// than backfillLockFreshWindow old — the daemon's phaseIdeas read side,
// checked before every cycle so a CLI backfill and the daemon's own
// consolidator never interleave over the same floors (spec §5). A missing
// lock file, or one whose "started=" timestamp cannot be parsed, reads as
// not-fresh: a read-side failure must never permanently wedge the daemon
// phase, and an unparseable lock is exactly the stale-crashed-run case
// AcquireBackfillLock already treats as safe to overwrite.
func BackfillLockFresh(workspaceDir string) bool {
	path := filepath.Join(workspaceDir, backfillLockFilename)
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	started, ok := parseLockStarted(string(data))
	if !ok {
		return false
	}
	return time.Since(started) < backfillLockFreshWindow
}

// parseLockStarted extracts the "started=<RFC3339>" timestamp from a lock
// file's contents.
func parseLockStarted(contents string) (time.Time, bool) {
	const marker = "started="
	idx := strings.Index(contents, marker)
	if idx < 0 {
		return time.Time{}, false
	}
	rest := strings.TrimSpace(contents[idx+len(marker):])
	t, err := time.Parse(time.RFC3339, rest)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}
