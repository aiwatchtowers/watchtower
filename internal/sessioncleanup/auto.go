package sessioncleanup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
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
// right before each removal, and no process is ever signalled
// (Request.NoTerminate).
const (
	// autoWindow is how long after its finish a session is still cleaned
	// up automatically.
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
	// Deps are the apply's; their Lock is replaced by TryLock.
	Deps Deps
	// Candidates lists the sessions finished at or after since, the
	// longest-waiting first.
	Candidates func(ctx context.Context, since time.Time) ([]AutoCandidate, error)
	// Live is the session host's live terminal rows. An error stops the
	// pass: without it a finished session still on screen would not count
	// as working in its worktree (W6).
	Live func(ctx context.Context) (map[int64]bool, error)
	// TryLock takes a repository's cleanup lock (keyed as Deps.Lock) when
	// it is free now; ok=false = another cleanup holds it, and that
	// session waits for the next pass. Each session's apply holds it only
	// for itself.
	TryLock func(repo string) (unlock func(), ok bool, err error)
	// Logf logs one line per session whose apply removed something or
	// failed; nil = silent.
	Logf func(format string, args ...any)
}

// AutoResult is one pass: the sessions applied, how many of those removed
// something (a worktree, a branch, a build folder), and the failures — an
// apply that failed, or one that ran but recorded a failure (counted in
// Applied too).
type AutoResult struct {
	Applied, Changed, Failed int
}

// LockPath is the cleanup lock of the repository whose git common dir is
// repo, beside the database at dbPath (the placement lock's sibling).
func LockPath(dbPath, repo string) string {
	sum := sha256.Sum256([]byte(repo))
	return filepath.Join(filepath.Dir(dbPath), "repo-"+hex.EncodeToString(sum[:8])+".cleanup.lock")
}

// AutoRun is one automatic pass at now: each due session (autoDue), until
// autoBatch were applied, is applied under its repository's lock with the
// host's live terminals, PruneBuilds and NoTerminate. A session whose
// repository is busy waits for the next pass; one whose apply fails is
// logged and the pass goes on; when ctx is done the pass stops with ctx's
// error.
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
		res, applyErr := autoApply(ctx, ad, c, liveIDs, now)
		switch {
		case errors.Is(applyErr, errCleanupBusy):
			continue
		case applyErr != nil:
			out.Failed++
			ad.logf("session cleanup: session %d: %v", c.SessionID, applyErr)
			continue
		}
		out.Applied++
		if removedSomething(res.Items) {
			out.Changed++
		}
		switch failure := resultFailure(res); {
		case failure != "":
			// The apply ran but recorded a failure (a git run, a build
			// folder, the result's save): a failure of the pass too.
			out.Failed++
			ad.logf("session cleanup: session %d: %s; %s", c.SessionID, failure, res.Summary)
		case removedSomething(res.Items):
			ad.logf("session cleanup: session %d: %s", c.SessionID, res.Summary)
		}
	}
	return out, nil
}

// errCleanupBusy: another cleanup of the repository holds its lock.
var errCleanupBusy = errors.New("another cleanup of the repository runs")

// autoApply applies one session with the lock only tried (busy →
// errCleanupBusy).
func autoApply(ctx context.Context, ad AutoDeps, c AutoCandidate, live []int64, now time.Time) (Result, error) {
	d := ad.Deps
	d.Lock = func(_ context.Context, repo string) (func(), error) {
		unlock, ok, err := ad.TryLock(repo)
		if err != nil {
			return nil, fmt.Errorf("trying the lock: %w", err)
		}
		if !ok {
			return nil, errCleanupBusy
		}
		return unlock, nil
	}
	res, err := Apply(ctx, d, Request{SessionID: c.SessionID, WorkbenchID: c.WorkbenchID, LiveSessions: live,
		NoSize: true, PruneBuilds: true, NoTerminate: true, Now: now}, nil)
	if err != nil {
		return res, fmt.Errorf("applying: %w", err)
	}
	return res, nil
}

// resultFailure names the failures an apply that returned no error still
// recorded: an item's error, a build folder's, the result's save; "" for
// none.
func resultFailure(res Result) string {
	var parts []string
	for _, it := range res.Items {
		if it.Error != "" {
			parts = append(parts, it.Key+": "+it.Error)
		}
		if it.BuildError != "" {
			parts = append(parts, it.Key+" build: "+it.BuildError)
		}
	}
	if res.ResultError != "" {
		parts = append(parts, "saving the result: "+res.ResultError)
	}
	return strings.Join(parts, "; ")
}

// removedSomething: an item was removed or a build folder deleted.
func removedSomething(items []Item) bool {
	for _, it := range items {
		if it.Done || len(it.BuildsRemoved) > 0 {
			return true
		}
	}
	return false
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
// result that does not decode counts as work left. Two keeps do not count:
// a worktree kept only for uncommitted changes whose builds the prune
// already checked (no commit, so no merge or push, can free it by itself),
// and a branch kept because it is checked out (its worktree's own item
// decides).
func leftWork(resultJSON string) bool {
	var r Result
	if json.Unmarshal([]byte(resultJSON), &r) != nil {
		return true
	}
	for _, it := range r.Items {
		if it.Error != "" {
			return true
		}
		if (it.Kind != KindWorktree && it.Kind != KindBranch) || it.Action != ActionKeep || settledReasons[it.Reason] {
			continue
		}
		if it.Kind == KindWorktree && it.Reason == ReasonUncommittedChanges && it.BuildsChecked {
			continue
		}
		if it.Kind == KindBranch && it.Reason == ReasonCheckedOut {
			continue
		}
		return true
	}
	return false
}
