package sessioncleanup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
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
	// autoQuiet is how long a session that never called finish_session must
	// have had no activity to count as ended (#2402).
	autoQuiet = 24 * time.Hour
	// autoRetry is how long a session whose last cleanup left work behind
	// waits before the next try (a branch merged or pushed since).
	autoRetry = time.Hour
	// autoBatch caps the sessions one pass applies: the longest-waiting
	// first, so every due session gets its turn over the passes. A failed
	// apply saves no result, so its session stays first: failures do not
	// count, or a few broken sessions would hold every pass's batch.
	autoBatch = 10
)

// AutoCandidate is an ended — finished, or quiet for autoQuiet with no
// finish_session (Quiet) — not deleting, agent session of a workbench
// (db.FinishedSessionForCleanup).
type AutoCandidate = db.FinishedSessionForCleanup

// AutoDeps are an automatic pass's collaborators.
type AutoDeps struct {
	// Deps are the apply's; their Lock is replaced by TryLock.
	Deps Deps
	// Candidates lists the sessions ended at or after since, the
	// longest-waiting first.
	Candidates func(ctx context.Context, since time.Time) ([]AutoCandidate, error)
	// Live is the session host's live terminal rows, read right before
	// each session's apply. An error skips that session (a failure of the
	// pass): without it a finished session still on screen would not
	// count as working in its worktree (W6).
	Live func(ctx context.Context) (map[int64]bool, error)
	// TryLock takes a repository's cleanup lock (keyed as Deps.Lock) when
	// it is free now; ok=false = another cleanup holds it, and that
	// session waits for the next pass. Each session's apply holds it only
	// for itself.
	TryLock func(repo string) (unlock func(), ok bool, err error)
	// Logf logs one line per session whose apply removed something or
	// failed; nil = silent.
	Logf func(format string, args ...any)
	// Workbenches lists every workbench (its live folders are read through
	// Deps.DB.BenchFolders): the repository pass covers each distinct
	// repository of their folders. nil = no repository pass.
	Workbenches func(ctx context.Context) ([]int64, error)
	// budget derives a part's ctx from the pass's; nil = context.WithTimeout.
	// A test's seam.
	budget func(context.Context, time.Duration) (context.Context, context.CancelFunc)
}

// AutoResult is one pass: the sessions applied, how many of those removed
// something (a worktree, a branch, a build folder), and the failures — an
// apply that failed, or one that ran but recorded a failure (counted in
// Applied too).
type AutoResult struct {
	Applied, Changed, Failed int
	// RepoChanged and RepoFailed count the repositories whose repository
	// pass removed something (a worktree, a branch, a build folder), and
	// those it failed in.
	RepoChanged, RepoFailed int
}

// LockPath is the cleanup lock of the repository whose git common dir is
// repo, beside the database at dbPath (the placement lock's sibling).
func LockPath(dbPath, repo string) string {
	sum := sha256.Sum256([]byte(repo))
	return filepath.Join(filepath.Dir(dbPath), "repo-"+hex.EncodeToString(sum[:8])+".cleanup.lock")
}

// AutoRun is one automatic pass at now, in two parts with a budget each,
// derived from ctx one after the other (#2402 step 0): neither borrows the
// other's unused time, so long session applies never starve the repository
// pass. First the sessions (sessionApplyBudget): each due session
// (autoDue), until autoBatch were applied, is applied under its
// repository's lock with the host's live terminals, PruneBuilds and
// NoTerminate. A session whose repository is busy waits for the next pass;
// one whose apply fails is logged and the pass goes on. Then, with
// Workbenches, the repository pass (repoPassBudget, repopass.go). A part
// whose ctx is done stops with ctx's error; the error is both parts'.
func AutoRun(ctx context.Context, ad AutoDeps, now time.Time) (AutoResult, error) {
	var out AutoResult
	sctx, cancel := ad.within(ctx, sessionApplyBudget)
	sessErr := ad.sessionPart(sctx, now, &out)
	cancel()
	if ad.Workbenches == nil {
		return out, sessErr
	}
	rctx, cancel := ad.within(ctx, repoPassBudget)
	defer cancel()
	return out, errors.Join(sessErr, ad.repositoryPass(rctx, &out))
}

// within is a part's ctx: ctx bounded by budget.
func (ad AutoDeps) within(ctx context.Context, budget time.Duration) (context.Context, context.CancelFunc) {
	if ad.budget != nil {
		return ad.budget(ctx, budget)
	}
	return context.WithTimeout(ctx, budget)
}

// sessionPart applies the due sessions (AutoRun's first part) and counts
// them in out.
func (ad AutoDeps) sessionPart(ctx context.Context, now time.Time, out *AutoResult) error {
	cands, err := ad.Candidates(ctx, now.Add(-autoWindow))
	if err != nil {
		return fmt.Errorf("listing finished sessions: %w", err)
	}
	var due []AutoCandidate
	for _, c := range cands {
		if autoDue(c, now) {
			due = append(due, c)
		}
	}
	for _, c := range due {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("the pass stopped: %w", err)
		}
		if out.Applied >= autoBatch {
			return nil
		}
		// The host's live runs, read right before this session's apply: a
		// terminal opened during the pass still counts. Unreadable: this
		// session waits for the next pass.
		liveIDs, err := ad.liveIDs(ctx)
		if err != nil {
			out.Failed++
			ad.logf("session cleanup: session %d: listing the live sessions: %v", c.SessionID, err)
			continue
		}
		// A quiet row has no finish for the apply to re-check: the host's
		// live set is its only sign of life, so one live there is skipped
		// this pass (it is not a failure; W6 would keep its worktree too).
		if c.Quiet && slices.Contains(liveIDs, c.SessionID) {
			continue
		}
		res, applyErr := autoApply(ctx, ad, c, liveIDs, now)
		switch {
		case errors.Is(applyErr, errCleanupBusy):
			continue
		case c.Quiet && errors.Is(applyErr, ErrSessionNotEnded):
			// Active again since it was listed: nothing removed, no failure.
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
	return nil
}

// errCleanupBusy: another cleanup of the repository holds its lock.
var errCleanupBusy = errors.New("another cleanup of the repository runs")

// autoApply applies one session with the lock only tried (busy →
// errCleanupBusy).
func autoApply(ctx context.Context, ad AutoDeps, c AutoCandidate, live []int64, now time.Time) (Result, error) {
	d := ad.tryingDeps()
	r := Request{SessionID: c.SessionID, WorkbenchID: c.WorkbenchID, LiveSessions: live,
		NoSize: true, PruneBuilds: true, NoTerminate: true, RequireEnded: !c.Quiet, Quiet: c.Quiet, QuietBefore: now.Add(-autoQuiet), BuildsChecked: checkedRoots(c),
		Now: now}
	if c.Quiet {
		// A quiet session has no finish to re-check: the host's live runs,
		// read again before each destructive step, are its sign of life.
		r.liveNow = ad.liveIDs
	}
	res, err := Apply(ctx, d, r, nil)
	if err != nil {
		return res, fmt.Errorf("applying: %w", err)
	}
	return res, nil
}

// tryingDeps are the apply's Deps whose Lock only tries the repository's
// lock (busy → errCleanupBusy).
func (ad AutoDeps) tryingDeps() Deps {
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
	return d
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

// endedAt is when the candidate ended: finished_at, or for a quiet row its
// last activity (a candidate built with only FinishedAt reads as it).
func endedAt(c AutoCandidate) time.Time {
	if c.EndedAt.IsZero() {
		return c.FinishedAt
	}
	return c.EndedAt
}

// checkedRoots are the worktree roots whose builds the session's last
// cleanup, when it ran after the session's latest finish, found nothing
// left to delete in (builds_checked): a retry does not walk them again. A
// result from before the finish (the session worked, and may have built,
// since) names none.
func checkedRoots(c AutoCandidate) []string {
	if c.CleanupAt.IsZero() || c.CleanupAt.Before(endedAt(c)) {
		return nil
	}
	var r Result
	if json.Unmarshal([]byte(c.CleanupResult), &r) != nil {
		return nil
	}
	var roots []string
	for _, it := range r.Items {
		if it.Kind == KindWorktree && it.BuildsChecked {
			roots = append(roots, strings.TrimPrefix(it.Key, "worktree:"))
		}
	}
	return roots
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

// liveIDs are the live rows Live reports, as a list.
func (ad AutoDeps) liveIDs(ctx context.Context) ([]int64, error) {
	live, err := ad.Live(ctx)
	if err != nil {
		return nil, err
	}
	ids := make([]int64, 0, len(live))
	for id, ok := range live {
		if ok {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (ad AutoDeps) logf(format string, args ...any) {
	if ad.Logf != nil {
		ad.Logf(format, args...)
	}
}

// autoDue: the session has had no cleanup since it ended, or its last
// one left something that may go later and is autoRetry old. A quiet row
// younger than autoQuiet is not due (it was active again after being
// listed).
func autoDue(c AutoCandidate, now time.Time) bool {
	if c.Quiet && now.Sub(c.EndedAt) < autoQuiet {
		return false
	}
	if c.CleanupAt.IsZero() || c.CleanupAt.Before(endedAt(c)) {
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
// result that does not decode counts as work left. One keep does not
// count: a worktree kept only for uncommitted changes whose builds the
// prune already checked (no commit, so no merge or push, can free it by
// itself). A branch kept because it is checked out does count (the owner
// may switch the folder off it); its retry does not walk builds already
// checked (checkedRoots).
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
		return true
	}
	return false
}

// DBCandidates is AutoDeps.Candidates over the database: finished sessions
// and ones quiet for autoQuiet at the time now() reads.
func DBCandidates(database *db.DB, now func() time.Time) func(context.Context, time.Time) ([]AutoCandidate, error) {
	return func(ctx context.Context, since time.Time) ([]AutoCandidate, error) {
		return database.EndedSessionsForCleanup(ctx, since, now().Add(-autoQuiet)) //nolint:wrapcheck // the caller names it
	}
}

// DBWorkbenches is AutoDeps.Workbenches over the database: every
// workbench's id, read under the pass's ctx.
func DBWorkbenches(database *db.DB) func(context.Context) ([]int64, error) {
	return database.WorkbenchIDs
}
