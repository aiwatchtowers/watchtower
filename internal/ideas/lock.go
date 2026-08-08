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
// exclusively creates ideas_backfill.lock (contents "pid=<n>
// started=<RFC3339>") and returns a release func that removes it. The
// freshness check and the create are deliberately NOT a check-then-write
// (that was a TOCTOU: two concurrent `ideas mine --from` invocations could
// both pass a freshness check before either wrote the file, and both believe
// they hold the lock). Instead the create itself is the atomic O_EXCL
// syscall that decides ownership; a losing create is reclaimed ONLY when the
// existing file is provably stale (BackfillLockFresh reports false) —
// removed and the exclusive create retried exactly once. A second collision
// on the retry means another process won that race, and this call errors out
// rather than looping.
func AcquireBackfillLock(workspaceDir string) (release func(), err error) {
	path := filepath.Join(workspaceDir, backfillLockFilename)

	if err := createLockFile(path); err != nil {
		if !os.IsExist(err) {
			return nil, fmt.Errorf("ideas: writing backfill lock: %w", err)
		}
		if BackfillLockFresh(workspaceDir) {
			return nil, fmt.Errorf("ideas: a backfill is already in progress (%s)", path)
		}
		if rerr := os.Remove(path); rerr != nil && !os.IsNotExist(rerr) {
			return nil, fmt.Errorf("ideas: removing stale backfill lock: %w", rerr)
		}
		if err := createLockFile(path); err != nil {
			if os.IsExist(err) {
				return nil, fmt.Errorf("ideas: a backfill is already in progress (%s)", path)
			}
			return nil, fmt.Errorf("ideas: writing backfill lock: %w", err)
		}
	}

	return func() {
		_ = os.Remove(path)
	}, nil
}

// createLockFile exclusively creates the lock file — os.IsExist(err) is true
// when one already exists, the race-free primitive AcquireBackfillLock's
// TOCTOU fix relies on — and writes this process's pid/timestamp into it. A
// write failure after a successful create removes the (now truncated/bad)
// file rather than leaving it behind: BackfillLockFresh would read it as
// stale anyway (unparseable contents), but there is no reason to leave a
// half-written file around when the create itself can just be undone.
func createLockFile(path string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	contents := fmt.Sprintf("pid=%d started=%s\n", os.Getpid(), time.Now().UTC().Format(time.RFC3339))
	if _, werr := f.WriteString(contents); werr != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return fmt.Errorf("writing lock contents: %w", werr)
	}
	return f.Close()
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
