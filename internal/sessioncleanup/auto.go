package sessioncleanup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"watchtower/internal/db"
)

// The automatic cleanup of ended sessions (board #2131, owner decisions in
// asks #1685 and #1695): the daemon applies the cleanup of every session
// that finished (finish_session) within autoWindow, with no item named, so
// its merged or pushed worktrees and branches go without anyone pressing a
// button — at the session's end and again after a later merge or push —
// and the build output of the worktrees it must keep goes too
// (Request.PruneBuilds). Every PROJ-18 catch still applies, re-checked
// right before each removal.
const (
	// autoWindow is how long after its finish a session is still cleaned
	// up automatically; older ones wait for the owner's Clean Up screen.
	autoWindow = 14 * 24 * time.Hour
	// autoRetry is how long a session whose last cleanup left work behind
	// waits before the next try (a branch merged or pushed since).
	autoRetry = time.Hour
	// autoBatch caps the sessions one pass applies: the longest-waiting
	// first, so every due session gets its turn over the passes. A failed
	// apply saves no result, so its session stays first: failures do not
	// count, or a few broken sessions would hold every pass's batch.
	autoBatch = 10
)

// AutoCandidate is a finished, not deleting, agent session of a workbench
// (db.FinishedSessionForCleanup).
type AutoCandidate = db.FinishedSessionForCleanup

// AutoDeps are an automatic pass's collaborators.
type AutoDeps struct {
	// Deps are the apply's; their Lock is not used (TryLock is).
	Deps Deps
	// Candidates lists the sessions finished at or after since, the
	// longest-waiting first.
	Candidates func(ctx context.Context, since time.Time) ([]AutoCandidate, error)
	// Live is the session host's live terminal rows. An error stops the
	// pass: without it a finished session still on screen would not count
	// as working in its worktree (W6).
	Live func(ctx context.Context) (map[int64]bool, error)
	// TryLock takes the workbench's cleanup lock when it is free now;
	// ok=false = another cleanup holds it, and that session waits for the
	// next pass.
	TryLock func(workbenchID int64) (unlock func(), ok bool, err error)
	// Logf logs one line per session applied or failed; nil = silent.
	Logf func(format string, args ...any)
}

// AutoResult is one pass: the sessions applied and those that failed.
type AutoResult struct {
	Applied, Failed int
}

// LockPath is the cleanup lock of workbench workbenchID beside the
// database at dbPath, the placement lock's sibling.
func LockPath(dbPath string, workbenchID int64) string {
	return filepath.Join(filepath.Dir(dbPath), fmt.Sprintf("workbench-%d.cleanup.lock", workbenchID))
}

// AutoRun is one automatic pass at now: each due session (autoDue), until
// autoBatch were applied, is applied under its workbench's lock with the host's
// live terminals and PruneBuilds. A session whose apply fails is logged and
// the pass goes on; when ctx is done the pass stops with ctx's error.
func AutoRun(ctx context.Context, ad AutoDeps, now time.Time) (AutoResult, error) {
	var out AutoResult
	cands, err := ad.Candidates(ctx, now.Add(-autoWindow))
	if err != nil {
		return out, fmt.Errorf("listing finished sessions: %w", err)
	}
	var due []AutoCandidate
	for _, c := range cands {
		if autoDue(c, now) {
			due = append(due, c)
		}
	}
	if len(due) == 0 {
		return out, nil
	}
	live, err := ad.Live(ctx)
	if err != nil {
		return out, fmt.Errorf("listing the live sessions: %w", err)
	}
	liveIDs := make([]int64, 0, len(live))
	for id, ok := range live {
		if ok {
			liveIDs = append(liveIDs, id)
		}
	}
	for _, c := range due {
		if err := ctx.Err(); err != nil {
			return out, fmt.Errorf("the pass stopped: %w", err)
		}
		if out.Applied >= autoBatch {
			break
		}
		switch applyErr := autoApply(ctx, ad, c, liveIDs, now); {
		case errors.Is(applyErr, errCleanupBusy):
			continue
		case applyErr != nil:
			out.Failed++
			ad.logf("session cleanup: session %d: %v", c.SessionID, applyErr)
		default:
			out.Applied++
		}
	}
	return out, nil
}

// errCleanupBusy: another cleanup of the workbench holds its lock.
var errCleanupBusy = errors.New("another cleanup of the workbench runs")

func autoApply(ctx context.Context, ad AutoDeps, c AutoCandidate, live []int64, now time.Time) error {
	unlock, ok, err := ad.TryLock(c.WorkbenchID)
	if err != nil {
		return err
	}
	if !ok {
		return errCleanupBusy
	}
	defer unlock()
	d := ad.Deps
	d.Lock = nil // held above
	res, err := Apply(ctx, d, Request{SessionID: c.SessionID, WorkbenchID: c.WorkbenchID, LiveSessions: live,
		NoSize: true, PruneBuilds: true, Now: now}, nil)
	if err != nil {
		return err
	}
	ad.logf("session cleanup: session %d: %s", c.SessionID, res.Summary)
	return nil
}

func (ad AutoDeps) logf(format string, args ...any) {
	if ad.Logf != nil {
		ad.Logf(format, args...)
	}
}

// autoDue: the session has had no cleanup since it finished, or its last
// one left something that may go later and is autoRetry old.
func autoDue(c AutoCandidate, now time.Time) bool {
	if c.CleanupAt.IsZero() || c.CleanupAt.Before(c.FinishedAt) {
		return true
	}
	return now.Sub(c.CleanupAt) >= autoRetry && leftWork(c.CleanupResult)
}

// settledReasons are keep reasons a later try cannot change: the item is
// not the session's to remove, or never removable.
var settledReasons = map[string]bool{
	ReasonMainFolder: true, ReasonWorkbenchFolder: true, ReasonClaudeHome: true,
	ReasonNotThisSession: true, ReasonExistedBeforeSession: true, ReasonCreatedUnknown: true,
	ReasonDefaultBranch: true, ReasonNotAWorktree: true, ReasonNotABranch: true,
}

// leftWork: the stored result keeps a worktree or branch for a reason that
// may change (unpushed, in use, a failed check…) or carries an error; a
// result that does not decode counts as work left.
func leftWork(resultJSON string) bool {
	var r Result
	if json.Unmarshal([]byte(resultJSON), &r) != nil {
		return true
	}
	for _, it := range r.Items {
		if it.Error != "" {
			return true
		}
		if (it.Kind == KindWorktree || it.Kind == KindBranch) && it.Action == ActionKeep && !settledReasons[it.Reason] {
			return true
		}
	}
	return false
}
