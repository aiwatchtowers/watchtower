package reviewai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/fsutil"
)

// One overview run at a time per branch folder (tech spec §3.7).
const (
	// LockWaitCap is the longest a streamed run waits for another run's
	// lock: above MaxRunBudget, so a live holder always finishes first.
	LockWaitCap = 50 * time.Minute
	// LockWaitEvery is how often a waiting run hears OnWait (it re-reads
	// the part rows the holder writes).
	LockWaitEvery = 5 * time.Second
	// holderSettle is how long a reader that finds no holder waits before
	// it reads once more: the holder writes its line just after its flock.
	holderSettle = 50 * time.Millisecond
)

// Owner texts of class busy (tech spec §3.7).
const (
	busyDesktopText = "Branch review is describing this branch now; run this again when it finishes — what it describes is kept."
	busyOtherText   = "Another run is describing this branch now; run this again when it finishes — what it describes is kept."
	busyWaitedText  = "Another overview of this branch is still running."
)

// Holder is what the lock's holder wrote into the lock file: who runs it
// (desktop, agent or cli) and since when. The zero Holder: not readable.
type Holder struct {
	By        string    `json:"by"`
	StartedAt time.Time `json:"started_at"`
}

// BusyError is a run that did not get the lock: held at once by Holder
// (a form that never waits), or still held after the wait's cap (Waited).
type BusyError struct {
	Holder Holder
	Waited bool
}

// Error is the owner's sentence.
func (e *BusyError) Error() string {
	switch {
	case e.Waited:
		return busyWaitedText
	case e.Holder.By == "desktop":
		return busyDesktopText
	}
	return busyOtherText
}

// RunError is e as the run's failure, class busy.
func (e *BusyError) RunError() *RunError { return &RunError{Class: ClassBusy, Text: e.Error()} }

// LockPath is the run lock of a workbench's snapshot folder, in the
// workspace (never the repository, REVIEW-01): keyed by the folder's real
// path, not the tree, so the agent's and the Desktop's snapshots of one
// branch share it.
func LockPath(workspaceDir string, projectID int64, folderRealPath string) string {
	sum := sha256.Sum256([]byte(folderRealPath))
	return filepath.Join(workspaceDir, "locks",
		fmt.Sprintf("review-overview-%d-%s.lock", projectID, hex.EncodeToString(sum[:])[:16]))
}

// LockWait makes AcquireRun wait for a held lock. Cap (0: LockWaitCap)
// bounds the wait; OnWait hears the holder at once and every Every (0:
// LockWaitEvery), on the caller's goroutine.
type LockWait struct {
	Cap, Every time.Duration
	OnWait     func(Holder)
}

// AcquireRun takes the run lock at path for by and writes the Holder into
// it; release drops it (the kernel drops it too when the process dies).
// With wait nil a held lock is a *BusyError at once; with wait it waits up
// to its cap, then a *BusyError with Waited. A done ctx while waiting is
// ctx's error.
func AcquireRun(ctx context.Context, path, by string, wait *LockWait) (release func(), err error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("creating the run lock's folder: %w", err)
	}
	unlock, ok, err := fsutil.TryLockFile(path)
	if err != nil {
		return nil, err
	}
	if ok {
		return holdAs(path, by, unlock), nil
	}
	if wait == nil {
		return nil, &BusyError{Holder: holderNow(path)}
	}
	return waitRun(ctx, path, by, *wait)
}

func waitRun(ctx context.Context, path, by string, wait LockWait) (func(), error) {
	if wait.Cap <= 0 {
		wait.Cap = LockWaitCap
	}
	if wait.Every <= 0 {
		wait.Every = LockWaitEvery
	}
	if wait.OnWait == nil {
		wait.OnWait = func(Holder) {}
	}
	capCtx, cancel := context.WithTimeout(ctx, wait.Cap)
	defer cancel()
	type result struct {
		unlock func()
		err    error
	}
	got := make(chan result, 1)
	go func() {
		unlock, err := fsutil.LockFile(capCtx, path)
		got <- result{unlock, err}
	}()
	tick := time.NewTicker(wait.Every)
	defer tick.Stop()
	wait.OnWait(holderNow(path))
	for {
		select {
		case r := <-got:
			switch {
			case r.err == nil:
				return holdAs(path, by, r.unlock), nil
			case ctx.Err() != nil:
				return nil, ctx.Err()
			case errors.Is(capCtx.Err(), context.DeadlineExceeded):
				return nil, &BusyError{Holder: ReadHolder(path), Waited: true}
			}
			return nil, r.err
		case <-tick.C:
			wait.OnWait(holderNow(path))
		}
	}
}

// holdAs writes the holder's line into the lock file. The file outlives
// the lock (fsutil), so release empties it first, and a failed write
// empties it too: a reader finds no holder rather than an earlier one.
func holdAs(path, by string, unlock func()) func() {
	b, _ := json.Marshal(Holder{By: by, StartedAt: time.Now().UTC()})
	if err := os.WriteFile(path, b, 0o600); err != nil {
		_ = os.Truncate(path, 0)
		log.Printf("reviewai: overview run lock: holder not written")
	}
	return func() {
		_ = os.Truncate(path, 0)
		unlock()
	}
}

// holderNow is the Holder a held lock names, read once more after
// holderSettle when it names none yet.
func holderNow(path string) Holder {
	if h := ReadHolder(path); h.By != "" {
		return h
	}
	time.Sleep(holderSettle)
	return ReadHolder(path)
}

// ReadHolder is the Holder the lock file at path names; the zero Holder
// when it is missing or unreadable.
func ReadHolder(path string) Holder {
	var h Holder
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &h)
	}
	return h
}
