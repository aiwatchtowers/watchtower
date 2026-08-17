package ideas

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// backfillLockFilename is the cross-process backfill lock — a plain file
// (not flock, unlike internal/memory/vault.go's Lock): AcquireBackfillLock's
// writer and BackfillLockFresh's reader run in different processes (a CLI
// `ideas mine --from` invocation and the long-lived daemon), and the daemon
// side only ever needs a cheap read for BackfillLockFresh, never to contend
// for the lock itself.
const backfillLockFilename = "ideas_backfill.lock"

// backfillLockFreshWindow is how long a lock file is honored before it is
// treated as stale (a crashed backfill that never removed its own lock) —
// spec §5.
const backfillLockFreshWindow = 2 * time.Hour

// backfillLockHeartbeatInterval is how often a HELD lock's started= stamp is
// refreshed while its holder runs (F7/D4). started= is written once at acquire
// and freshness is judged on it (BackfillLockFresh), so without a periodic
// re-stamp a legitimate run outliving backfillLockFreshWindow would read as
// stale and a concurrent acquire could reclaim it mid-run — two live miners.
// Comfortably shorter than the freshness window; a package-level var so tests
// can shrink it (SetBackfillLockHeartbeatIntervalForTest).
var backfillLockHeartbeatInterval = 30 * time.Minute

// AcquireBackfillLock takes the ideas backfill lock in workspaceDir: it
// exclusively creates ideas_backfill.lock (contents "pid=<n>
// started=<RFC3339> owner=<owner>") and returns a release func that removes
// it. owner tags who is holding the lock ("daemon" or "CLI backfill", GB7 —
// spec §5 promises MUTUAL exclusion: both the daemon's phaseIdeas and a CLI
// `ideas mine --from` backfill call this, so a losing side on either end
// gets a clear "the X is mining right now" error naming the actual holder.
//
// The freshness check and the create are deliberately NOT a check-then-write
// (that was a TOCTOU: two concurrent callers could both pass a freshness
// check before either wrote the file, and both believe they hold the lock).
// Instead the create itself is the atomic O_EXCL syscall that decides
// ownership; a losing create is reclaimed ONLY when the existing file is
// provably stale (BackfillLockFresh reports false) — removed and the
// exclusive create retried exactly once. A second collision on the retry
// means another process won that race, and this call errors out rather than
// looping.
//
// The returned release is ownership-checked (GB7): it only removes the file
// if its contents still match exactly what THIS call wrote. Without that
// check, a caller whose lock went stale and was reclaimed by someone else —
// this process was merely slow, not actually gone — would have its eventual
// deferred release blindly delete the NEW owner's fresh lock instead of its
// own already-gone one.
func AcquireBackfillLock(workspaceDir, owner string) (release func(), err error) {
	path := filepath.Join(workspaceDir, backfillLockFilename)

	written, err := createLockFile(path, owner)
	if err != nil {
		if !os.IsExist(err) {
			return nil, fmt.Errorf("ideas: writing backfill lock: %w", err)
		}
		if BackfillLockFresh(workspaceDir) {
			return nil, alreadyMiningError(path)
		}
		if rerr := os.Remove(path); rerr != nil && !os.IsNotExist(rerr) {
			return nil, fmt.Errorf("ideas: removing stale backfill lock: %w", rerr)
		}
		written, err = createLockFile(path, owner)
		if err != nil {
			if os.IsExist(err) {
				return nil, alreadyMiningError(path)
			}
			return nil, fmt.Errorf("ideas: writing backfill lock: %w", err)
		}
	}

	// Keep the lock's started= stamp fresh for as long as this holder runs, so
	// a run longer than backfillLockFreshWindow is never judged stale and
	// reclaimed out from under itself (F7/D4). The returned release stops the
	// heartbeat and performs the ownership-checked removal.
	return startLockHeartbeat(path, owner, written).stop, nil
}

// lockHeartbeat keeps a held backfill lock's started= stamp fresh for the life
// of its holder (F7/D4). own holds the exact bytes this holder last wrote,
// mutex-guarded because the ticker goroutine updates it and stop() reads it; it
// is cleared to "" once the file is observed reclaimed by another process,
// after which neither the heartbeat nor the release will touch it (GB7).
type lockHeartbeat struct {
	path  string
	owner string
	mu    sync.Mutex
	own   string
	done  chan struct{}
	wg    sync.WaitGroup
}

// startLockHeartbeat launches the re-stamp ticker for a freshly-acquired lock
// whose current on-disk contents are initial.
func startLockHeartbeat(path, owner, initial string) *lockHeartbeat {
	h := &lockHeartbeat{path: path, owner: owner, own: initial, done: make(chan struct{})}
	h.wg.Add(1)
	go h.loop()
	return h
}

func (h *lockHeartbeat) loop() {
	defer h.wg.Done()
	t := time.NewTicker(backfillLockHeartbeatInterval)
	defer t.Stop()
	for {
		select {
		case <-h.done:
			return
		case <-t.C:
			h.beat()
		}
	}
}

// beat re-stamps started= if this holder still owns the file. A missing file
// or contents that no longer match what this holder last wrote mean the lock
// went stale and was reclaimed — beat gives up ownership so neither it nor the
// eventual release ever overwrites or removes the new owner's lock (GB7).
func (h *lockHeartbeat) beat() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.own == "" {
		return
	}
	data, err := os.ReadFile(h.path)
	if err != nil || string(data) != h.own {
		h.own = "" // reclaimed or gone — stop owning
		return
	}
	refreshed := lockContents(h.owner)
	if err := os.WriteFile(h.path, []byte(refreshed), 0o644); err != nil {
		return // keep the old own; retry next tick
	}
	h.own = refreshed
}

// stop halts the heartbeat and releases the lock, ownership-checked (GB7): it
// removes the file only if it still holds exactly the bytes this holder last
// wrote.
func (h *lockHeartbeat) stop() {
	close(h.done)
	h.wg.Wait()
	h.mu.Lock()
	own := h.own
	h.mu.Unlock()
	if own == "" {
		return
	}
	releaseIfStillOwned(h.path, own)
}

// SetBackfillLockHeartbeatIntervalForTest shrinks the heartbeat interval for
// the life of a test (the SetBackfillMaxCyclesForTest precedent) so a re-stamp
// is observable without waiting the production 30 minutes.
func SetBackfillLockHeartbeatIntervalForTest(d time.Duration) (restore func()) {
	prev := backfillLockHeartbeatInterval
	backfillLockHeartbeatInterval = d
	return func() { backfillLockHeartbeatInterval = prev }
}

// createLockFile exclusively creates the lock file — os.IsExist(err) is true
// when one already exists, the race-free primitive AcquireBackfillLock's
// TOCTOU fix relies on — and writes this process's pid/timestamp/owner into
// it, returning the exact bytes written so the caller's release can later
// verify it still owns this lock before removing it. A write failure after a
// successful create removes the (now truncated/bad) file rather than leaving
// it behind: BackfillLockFresh would read it as stale anyway (unparseable
// contents), but there is no reason to leave a half-written file around when
// the create itself can just be undone.
func createLockFile(path, owner string) (string, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return "", err
	}
	contents := lockContents(owner)
	if _, werr := f.WriteString(contents); werr != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return "", fmt.Errorf("writing lock contents: %w", werr)
	}
	if cerr := f.Close(); cerr != nil {
		return "", fmt.Errorf("closing lock file: %w", cerr)
	}
	return contents, nil
}

// lockContents renders a lock file's body for this process: pid, a fresh
// started= stamp, and the owner tag. createLockFile and the heartbeat both go
// through it so the two produce identical shapes. The stamp is RFC3339Nano so a
// heartbeat re-stamp is observably newer than the last even within the same
// wall-clock second; parseLockStarted's RFC3339 parse accepts the fractional
// seconds and older second-resolution locks alike.
func lockContents(owner string) string {
	return fmt.Sprintf("pid=%d started=%s owner=%s\n", os.Getpid(), time.Now().UTC().Format(time.RFC3339Nano), owner)
}

// releaseIfStillOwned removes the lock file only if its current contents
// still exactly match what this call's AcquireBackfillLock wrote (GB7) — a
// missing file (already released, or never fully written) or contents that
// no longer match (reclaimed by another process as stale) are both left
// alone; there is nothing this call still owns to remove.
func releaseIfStillOwned(path, ownContents string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	if string(data) != ownContents {
		return
	}
	_ = os.Remove(path)
}

// alreadyMiningError builds the "the X is mining right now" error a losing
// AcquireBackfillLock call returns, naming whichever owner tag the current
// lock file records. Reading the owner is best-effort: an unreadable or
// untagged lock (e.g. one predating this field) falls back to a generic
// phrase rather than failing the error path itself.
func alreadyMiningError(path string) error {
	owner := "another process"
	if data, rerr := os.ReadFile(path); rerr == nil {
		if o, ok := parseLockOwner(string(data)); ok {
			owner = o
		}
	}
	return fmt.Errorf("ideas: the %s is mining right now (%s)", owner, path)
}

// BackfillLockFresh reports whether workspaceDir holds a backfill lock less
// than backfillLockFreshWindow old — used by callers that only need a cheap
// read (AcquireBackfillLock's own collision check, and any read-only caller
// that wants to know without contending for the lock itself). A missing lock
// file, or one whose "started=" timestamp cannot be parsed, reads as
// not-fresh: a read-side failure must never permanently wedge a caller, and
// an unparseable lock is exactly the stale-crashed-run case
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
	if sp := strings.IndexByte(rest, ' '); sp >= 0 {
		rest = rest[:sp]
	}
	t, err := time.Parse(time.RFC3339, rest)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// parseLockOwner extracts the "owner=<tag>" value from a lock file's
// contents, up to the end of the line.
func parseLockOwner(contents string) (string, bool) {
	const marker = "owner="
	idx := strings.Index(contents, marker)
	if idx < 0 {
		return "", false
	}
	rest := contents[idx+len(marker):]
	if nl := strings.IndexByte(rest, '\n'); nl >= 0 {
		rest = rest[:nl]
	}
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return "", false
	}
	return rest, true
}
