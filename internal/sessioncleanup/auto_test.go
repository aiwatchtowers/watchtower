package sessioncleanup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// TestApply_TakesTheRepositoryLockFirst: an apply takes Deps.Lock for the
// repository it acts on — keyed by its git common dir, so a sweep of the
// workbench and a session of another workbench over the same repository
// take the same lock — and holds it to its end; a lock that cannot be
// taken fails the apply before anything is evaluated or removed.
func TestApply_TakesTheRepositoryLockFirst(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")

	refused := errors.New("held elsewhere")
	d := f.deps()
	d.Lock = func(context.Context, string) (func(), error) { return nil, refused }
	if _, err := Apply(context.Background(), d, Request{SessionID: testSession}, nil); !errors.Is(err, refused) {
		t.Fatalf("err = %v, want the lock's", err)
	}
	if !exists(root) {
		t.Fatal("removed without the lock")
	}

	var locked []string
	held := false
	d.Lock = func(_ context.Context, repo string) (func(), error) {
		locked, held = append(locked, repo), true
		return func() { held = false }, nil
	}
	d.Git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		if !held && !slices.Equal(args, []string{"rev-parse", "--git-common-dir"}) { // the key is read first
			t.Errorf("git %s ran without the lock", strings.Join(args, " "))
		}
		return nil
	}}
	res, err := Apply(context.Background(), d, Request{SessionID: testSession}, nil)
	if err != nil {
		t.Fatal(err)
	}
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	repo := filepath.Join(f.repo, ".git")
	if len(locked) != 1 || locked[0] != repo || held {
		t.Fatalf("locked %v, still held %v; want %s", locked, held, repo)
	}
	// Another workbench over the same repository, its sweep: the same key.
	f.store.folders[testWorkbench+1] = f.repo
	f.store.session.WorkbenchID = testWorkbench + 1
	for _, r := range []Request{{SessionID: testSession}, {Sweep: true, WorkbenchID: testWorkbench}} {
		sc, err := readScope(context.Background(), f.deps(), r)
		if err != nil {
			t.Fatal(err)
		}
		keys, _ := lockKeys(context.Background(), f.deps(), sc.folders(r.Sweep))
		if len(keys) != 1 || keys[0] != repo {
			t.Fatalf("%+v: keys %v, err %v", r, keys, err)
		}
	}
}

// autoFixture is a fixture with the automatic pass's seams.
type autoFixture struct {
	*fixture
	cands   []AutoCandidate
	live    map[int64]bool
	liveErr error
	// liveFn, when set, answers Live instead of live/liveErr.
	liveFn  func() (map[int64]bool, error)
	busy    bool
	locked  []string
	results *fakeResults
	logf    func(format string, args ...any)
}

func newAutoFixture(t *testing.T) *autoFixture {
	t.Helper()
	return &autoFixture{fixture: newFixture(t), live: map[int64]bool{}, results: &fakeResults{}}
}

func (a *autoFixture) run(now time.Time) (AutoResult, error) {
	a.t.Helper()
	d := a.deps()
	d.Results = a.results
	d.Lock = func(context.Context, string) (func(), error) {
		a.t.Error("the pass took the waiting lock")
		return func() {}, nil
	}
	return AutoRun(context.Background(), AutoDeps{
		Deps: d,
		Candidates: func(_ context.Context, since time.Time) ([]AutoCandidate, error) {
			if want := now.Add(-autoWindow); !since.Equal(want) {
				a.t.Errorf("since = %v, want %v", since, want)
			}
			return a.cands, nil
		},
		Live: func(context.Context) (map[int64]bool, error) {
			if a.liveFn != nil {
				return a.liveFn()
			}
			return a.live, a.liveErr
		},
		TryLock: func(repo string) (func(), bool, error) {
			if a.busy {
				return nil, false, nil
			}
			a.locked = append(a.locked, repo)
			return func() {}, true, nil
		},
		Logf: a.logf,
	}, now)
}

// TestProj18_AutoCleanupOfAFinishedSession (#2131, ask #1685): the pass
// applies a finished session's cleanup with no item named — its pushed
// worktree and branch go, its unpushed one stays without its build — under
// the workbench lock, and saves the result.
func TestProj18_AutoCleanupOfAFinishedSession(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	pushed := a.pushedWork("wt-pushed", "feat/pushed")
	a.record(pushed, "feat/pushed")
	kept := a.worktree("wt-kept", "feat/kept")
	a.commit(kept, ".gitignore", ".build/\n")
	a.record(kept, "feat/kept")
	build := swiftBuild(t, filepath.Join(kept, ".build"))
	a.endSession()
	now := time.Now()
	a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now.Add(-time.Minute)}}

	res, err := a.run(now)
	if err != nil || res.Applied != 1 || res.Failed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if exists(pushed) || a.branchExists("feat/pushed") {
		t.Fatal("the pushed work stayed")
	}
	if !a.listsWorktree(kept) || exists(build) {
		t.Fatalf("kept worktree listed %v, build exists %v", a.listsWorktree(kept), exists(build))
	}
	if len(a.locked) != 1 || a.locked[0] != filepath.Join(a.repo, ".git") || a.results.sessionID != testSession {
		t.Fatalf("locked %v, saved for %d", a.locked, a.results.sessionID)
	}
}

// TestProj18_AutoCleanupKeepsWhatIsInUse: a finished session whose terminal
// is still live keeps the worktree it works in, and its build.
func TestProj18_AutoCleanupKeepsWhatIsInUse(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	root := a.pushedWork("wt", "feat/x")
	a.commit(root, ".gitignore", ".build/\n")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	a.record(root, "feat/x")
	build := swiftBuild(t, filepath.Join(root, ".build"))
	a.endSession()
	a.store.activity[0].AgentCwd = root
	a.live[testSession] = true
	now := time.Now()
	a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now}}

	if _, err := a.run(now); err != nil {
		t.Fatal(err)
	}
	if !a.listsWorktree(root) || !exists(filepath.Join(build, buildMarker)) {
		t.Fatal("the worktree in use or its build went")
	}
}

// TestAutoRun_SkipsBusyAndFailsClosedOnLive: a repository whose lock is
// held is skipped this pass; a session whose live list cannot be read is
// skipped too (a failure), nothing applied.
func TestAutoRun_SkipsBusyAndFailsClosedOnLive(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	root := a.pushedWork("wt", "feat/x")
	a.record(root, "feat/x")
	a.endSession()
	now := time.Now()
	a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now}}

	a.busy = true
	if res, err := a.run(now); err != nil || res != (AutoResult{}) {
		t.Fatalf("busy: res %+v, err %v", res, err)
	}
	a.busy, a.liveErr = false, errors.New("host refused")
	if res, err := a.run(now); err != nil || res.Failed != 1 || res.Applied != 0 {
		t.Fatalf("no live list: res %+v, err %v", res, err)
	}
	if !exists(root) || len(a.locked) != 0 {
		t.Fatal("something was applied")
	}
}

// TestAutoDue: never cleaned, or cleaned before the finish → due; cleaned
// after the finish → due only autoRetry later and only while the result
// left work that may still go — a worktree kept only for uncommitted
// changes whose builds were checked is not (review F6); a branch kept
// checked out is (review round 3).
func TestAutoDue(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC)
	finished := now.Add(-3 * time.Hour)
	result := func(items ...Item) string {
		b, err := json.Marshal(Result{Plan: Plan{Items: items}})
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	unpushed := result(Item{Kind: KindWorktree, Action: ActionKeep, Reason: ReasonUnpushedCommits})
	settled := result(Item{Kind: KindWorktree, Action: ActionKeep, Reason: ReasonNotThisSession},
		Item{Kind: KindBranch, Action: ActionRemove, Done: true})
	failed := result(Item{Kind: KindBranch, Action: ActionRemove, Error: "boom"})
	for name, tc := range map[string]struct {
		cleaned time.Time
		result  string
		want    bool
	}{
		"never":                      {want: true},
		"before the finish":          {cleaned: finished.Add(-time.Minute), result: settled, want: true},
		"recent, work left":          {cleaned: now.Add(-autoRetry / 2), result: unpushed},
		"old, work left":             {cleaned: now.Add(-autoRetry), result: unpushed, want: true},
		"old, settled":               {cleaned: now.Add(-autoRetry), result: settled},
		"old, an error":              {cleaned: now.Add(-autoRetry), result: failed, want: true},
		"old, unreadable result":     {cleaned: now.Add(-autoRetry), result: "{", want: true},
		"old, in use (may go later)": {cleaned: now.Add(-autoRetry), result: result(Item{Kind: KindWorktree, Action: ActionKeep, Reason: ReasonSessionInIt}), want: true},
		"old, uncommitted, builds checked": {cleaned: now.Add(-autoRetry), result: result(
			Item{Kind: KindWorktree, Action: ActionKeep, Reason: ReasonUncommittedChanges, BuildsChecked: true})},
		"old, a branch checked out": {cleaned: now.Add(-autoRetry), want: true, result: result(
			Item{Kind: KindWorktree, Action: ActionKeep, Reason: ReasonUncommittedChanges, BuildsChecked: true},
			Item{Kind: KindBranch, Action: ActionKeep, Reason: ReasonCheckedOut})},
		"old, uncommitted, builds not checked": {cleaned: now.Add(-autoRetry), want: true, result: result(
			Item{Kind: KindWorktree, Action: ActionKeep, Reason: ReasonUncommittedChanges})},
		"old, unpushed, builds checked": {cleaned: now.Add(-autoRetry), want: true, result: result(
			Item{Kind: KindWorktree, Action: ActionKeep, Reason: ReasonUnpushedCommits, BuildsChecked: true})},
	} {
		c := AutoCandidate{SessionID: 1, WorkbenchID: 1, FinishedAt: finished, CleanupAt: tc.cleaned, CleanupResult: tc.result}
		if got := autoDue(c, now); got != tc.want {
			t.Errorf("%s: due = %v, want %v", name, got, tc.want)
		}
	}
}

// TestAutoRun_BatchCap: one pass applies at most autoBatch sessions; a
// failed apply does not count, so failing sessions never hold the batch.
func TestAutoRun_BatchCap(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	a.endSession()
	now := time.Now()
	broken := AutoCandidate{SessionID: 404, WorkbenchID: testWorkbench, FinishedAt: now} // no such row: fails
	for range autoBatch {
		a.cands = append(a.cands, broken)
	}
	for range autoBatch + 3 {
		a.cands = append(a.cands, AutoCandidate{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now})
	}
	res, err := a.run(now)
	if err != nil || res.Failed != autoBatch || res.Applied != autoBatch {
		t.Fatalf("res %+v, err %v", res, err)
	}
}

// TestAutoRun_StopsWhenCancelled: a pass whose ctx is done (the daemon
// stopping, the budget spent) applies nothing more and says why.
func TestAutoRun_StopsWhenCancelled(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res, err := AutoRun(ctx, AutoDeps{
		Candidates: func(context.Context, time.Time) ([]AutoCandidate, error) {
			return []AutoCandidate{{SessionID: 1, WorkbenchID: 1, FinishedAt: time.Now()}}, nil
		},
		Live: func(context.Context) (map[int64]bool, error) { return nil, nil },
		TryLock: func(string) (func(), bool, error) {
			t.Error("a cancelled pass took a lock")
			return func() {}, true, nil
		},
	}, time.Now())
	if !errors.Is(err, context.Canceled) || res != (AutoResult{}) {
		t.Fatalf("res %+v, err %v", res, err)
	}
}

// TestProj18_AutoCleanupSignalsNoProcess (#2131, review F1): an orphan of
// the session in a worktree that could otherwise go — an app the owner
// opened from the session's build — is never signalled by the automatic
// pass; the worktree stays (process_running), its build too.
func TestProj18_AutoCleanupSignalsNoProcess(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	root := a.pushedWork("wt", "feat/x")
	a.commit(root, ".gitignore", ".build/\n")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	a.record(root, "feat/x")
	build := swiftBuild(t, filepath.Join(root, ".build"))
	a.procs.list = []Proc{{PID: 4245, PPID: 1, UID: os.Getuid(), Start: "s",
		Exe: filepath.Join(build, "debug", "App"), Cwd: "/"}}
	a.endSession()
	now := time.Now()
	a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now}}

	if _, err := a.run(now); err != nil {
		t.Fatal(err)
	}
	if len(a.procs.terminated) > 0 {
		t.Fatalf("signalled %+v", a.procs.terminated)
	}
	if !a.listsWorktree(root) || !exists(filepath.Join(build, buildMarker)) {
		t.Fatal("the worktree or its build went")
	}
	var saved Result
	if err := json.Unmarshal([]byte(a.results.body), &saved); err != nil {
		t.Fatal(err)
	}
	wantItem(t, saved.Plan, "worktree:"+root, ActionKeep, ReasonProcessRunning)
}

// TestAutoRun_RecordedFailureCountsAsFailed (review round 2): an apply that
// returns no error but records a failure — here its result could not be
// saved — is a failure of the pass, logged with the session and the error,
// even when it removed something.
func TestAutoRun_RecordedFailureCountsAsFailed(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	root := a.pushedWork("wt", "feat/x")
	a.record(root, "feat/x")
	a.endSession()
	a.results.failWith = errors.New("database is locked")
	now := time.Now()
	a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now}}
	var lines []string
	a.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }

	res, err := a.run(now)
	if err != nil || res.Applied != 1 || res.Changed != 1 || res.Failed != 1 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if len(lines) != 1 || !strings.Contains(lines[0], fmt.Sprintf("session %d", testSession)) ||
		!strings.Contains(lines[0], "database is locked") {
		t.Fatalf("log %q", lines)
	}
}

// TestResultFailure names an item's error, a build error and a save error.
func TestResultFailure(t *testing.T) {
	t.Parallel()
	if got := resultFailure(Result{Plan: Plan{Items: []Item{{Key: "worktree:/w", Done: true}}}}); got != "" {
		t.Fatalf("clean result: %q", got)
	}
	got := resultFailure(Result{Plan: Plan{Items: []Item{
		{Key: "worktree:/w", Action: ActionKeep, BuildError: "moving aside: denied"},
		{Key: "branch:x", Error: "update-ref failed"},
	}}, ResultError: "locked"})
	for _, want := range []string{"worktree:/w build: moving aside: denied", "branch:x: update-ref failed", "saving the result: locked"} {
		if !strings.Contains(got, want) {
			t.Errorf("%q lacks %q", got, want)
		}
	}
}

// TestProj18_AutoCleanupOfAResumedSessionRemovesNothing (review round 3):
// a session listed as finished that resumed before its apply — or between
// the apply's evaluation and its removals — loses nothing.
func TestProj18_AutoCleanupOfAResumedSessionRemovesNothing(t *testing.T) {
	t.Parallel()
	for name, resumeLate := range map[string]bool{"before the apply": false, "during the apply": true} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			a := newAutoFixture(t)
			root := a.pushedWork("wt", "feat/x")
			a.commit(root, ".gitignore", ".build/\n")
			gitIn(t, root, "push", "-q", "origin", "feat/x") // removable, but for the resume
			a.record(root, "feat/x")
			build := swiftBuild(t, filepath.Join(root, ".build"))
			a.endSession()
			now := time.Now()
			a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now}}
			resume := func() { a.store.activity[0].Finished = false }
			if resumeLate {
				g := &flipGit{flip: resume}
				a.git = g
			} else {
				resume()
			}
			res, err := a.run(now)
			if err != nil || res.Changed != 0 || (!resumeLate && res.Failed != 1) {
				t.Fatalf("res %+v, err %v", res, err)
			}
			if !a.listsWorktree(root) || !a.branchExists("feat/x") || !exists(filepath.Join(build, buildMarker)) {
				t.Fatal("something of the resumed session went")
			}
		})
	}
}

// quietSession registers the session as never finished (no finish_session),
// quiet since ended, and lists it as a quiet candidate.
func (a *autoFixture) quietSession(ended time.Time) {
	a.store.activity = append(a.store.activity, SessionActivity{ID: testSession, WorkbenchID: testWorkbench, Title: "the session"})
	a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, EndedAt: ended, Quiet: true}}
}

// TestProj18_QuietSessionIsCleanedUp (#2402): a session that never called
// finish_session but has been quiet for 24 h is applied like a finished one:
// its pushed work goes, and the kept worktree loses its build.
func TestProj18_QuietSessionIsCleanedUp(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	pushed := a.pushedWork("wt-pushed", "feat/pushed")
	a.record(pushed, "feat/pushed")
	kept := a.worktree("wt-kept", "feat/kept")
	a.commit(kept, ".gitignore", ".build/\n")
	a.record(kept, "feat/kept")
	build := swiftBuild(t, filepath.Join(kept, ".build"))
	now := time.Now()
	a.quietSession(now.Add(-30 * time.Hour))

	res, err := a.run(now)
	if err != nil || res.Applied != 1 || res.Failed != 0 || res.Changed != 1 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if exists(pushed) || a.branchExists("feat/pushed") {
		t.Fatal("the pushed work of the quiet session stayed")
	}
	if !a.listsWorktree(kept) || exists(build) {
		t.Fatalf("kept worktree listed %v, build exists %v (the quiet session's build must go)", a.listsWorktree(kept), exists(build))
	}
}

// TestProj18_QuietSessionLosesKeptWorktreesBuild: a quiet session's kept
// (unpushed) worktree loses its build in the same apply, the work stays.
func TestProj18_QuietSessionLosesKeptWorktreesBuild(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	root, builds := a.unpushedWithBuild()
	now := time.Now()
	a.quietSession(now.Add(-25 * time.Hour))

	if res, err := a.run(now); err != nil || res.Failed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !a.listsWorktree(root) || !a.branchExists("feat/x") {
		t.Fatal("the unpushed work went")
	}
	for _, b := range builds {
		if exists(b) {
			t.Fatalf("build %s survived", b)
		}
	}
}

// TestProj18_LiveQuietSessionIsSkipped: a quiet row that is live in the host
// is skipped for this pass (not a failure), nothing of it is touched.
func TestProj18_LiveQuietSessionIsSkipped(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	root := a.pushedWork("wt", "feat/x")
	a.record(root, "feat/x")
	now := time.Now()
	a.quietSession(now.Add(-30 * time.Hour))
	a.live[testSession] = true

	res, err := a.run(now)
	if err != nil || res != (AutoResult{}) {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !a.listsWorktree(root) || !a.branchExists("feat/x") || len(a.locked) != 0 {
		t.Fatal("something of the live quiet session was touched")
	}
}

// TestProj18_QuietCandidateActiveAgainRemovesNothing: a quiet row that is
// active again by the apply (its terminal reopened, or it lists no longer
// quiet) loses nothing — the host's live set read right before the apply
// skips it, a candidate under 24 h is not due.
func TestProj18_QuietCandidateActiveAgainRemovesNothing(t *testing.T) {
	t.Parallel()
	for name, tc := range map[string]struct {
		ended time.Duration
		live  bool
	}{"reopened before the apply": {ended: 30 * time.Hour, live: true}, "active within 24 h": {ended: 2 * time.Hour}} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			a := newAutoFixture(t)
			root := a.pushedWork("wt", "feat/x")
			a.record(root, "feat/x")
			now := time.Now()
			a.quietSession(now.Add(-tc.ended))
			a.live[testSession] = tc.live
			if res, err := a.run(now); err != nil || res.Changed != 0 || res.Failed != 0 {
				t.Fatalf("res %+v, err %v", res, err)
			}
			if !a.listsWorktree(root) || !a.branchExists("feat/x") {
				t.Fatal("something of the active session went")
			}
		})
	}
}

// TestProj18_QuietSessionReopenedAfterListingKeepsItsWork: a quiet row whose
// stored activity moved forward after the candidate list was read (a reopen
// writes last_active_at before the host run exists, so the live set is
// still empty) loses nothing and is no failure; the same when the activity
// moves between the apply's evaluation and its removals.
func TestProj18_QuietSessionReopenedAfterListingKeepsItsWork(t *testing.T) {
	t.Parallel()
	for name, late := range map[string]bool{"before the apply": false, "during the apply": true} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			a := newAutoFixture(t)
			root := a.pushedWork("wt", "feat/x")
			a.commit(root, ".gitignore", ".build/\n")
			gitIn(t, root, "push", "-q", "origin", "feat/x")
			a.record(root, "feat/x")
			build := swiftBuild(t, filepath.Join(root, ".build"))
			now := time.Now()
			a.quietSession(now.Add(-30 * time.Hour))
			reopen := func() { a.store.activity[0].LastActive = now.Add(-time.Minute) }
			if late {
				a.git = &flipGit{flip: reopen}
			} else {
				reopen()
			}
			res, err := a.run(now)
			if err != nil || res.Changed != 0 || (!late && res.Failed != 0) {
				t.Fatalf("res %+v, err %v", res, err)
			}
			if !a.listsWorktree(root) || !a.branchExists("feat/x") || !exists(filepath.Join(build, buildMarker)) {
				t.Fatal("something of the reopened session went")
			}
		})
	}
}

// TestAutoDue_QuietMeasuresFromEndedAt: a quiet row's retry and "cleaned
// since it ended" read from EndedAt, not the zero FinishedAt.
func TestAutoDue_QuietMeasuresFromEndedAt(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC)
	ended := now.Add(-30 * time.Hour)
	if !autoDue(AutoCandidate{Quiet: true, EndedAt: ended, CleanupAt: ended.Add(-time.Minute), CleanupResult: "{}"}, now) {
		t.Error("cleaned before it went quiet: due")
	}
	if autoDue(AutoCandidate{Quiet: true, EndedAt: ended, CleanupAt: now.Add(-time.Hour), CleanupResult: "{}"}, now) {
		t.Error("cleaned after, nothing left: not due")
	}
	if autoDue(AutoCandidate{Quiet: true, EndedAt: now.Add(-time.Hour)}, now) {
		t.Error("quiet for under autoQuiet: not due")
	}
}

// TestAutoRun_RetryDoesNotWalkCheckedBuilds (review round 3): a retry after
// a cleanup that, since the finish, checked a kept worktree's builds does
// not walk them again; after a new finish it does.
func TestAutoRun_RetryDoesNotWalkCheckedBuilds(t *testing.T) {
	t.Parallel()
	for name, tc := range map[string]struct {
		cleanedAfterFinish, wantPruned bool
	}{"checked since the finish": {cleanedAfterFinish: true}, "checked before a new finish": {wantPruned: true}} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			a := newAutoFixture(t)
			root, builds := a.unpushedWithBuild()
			a.endSession()
			now := time.Now()
			prev, err := json.Marshal(Result{Plan: Plan{Items: []Item{{Key: "worktree:" + root, Kind: KindWorktree,
				Action: ActionKeep, Reason: ReasonUnpushedCommits, BuildsChecked: true}}}})
			if err != nil {
				t.Fatal(err)
			}
			finished, cleaned := now.Add(-3*time.Hour), now.Add(-2*time.Hour)
			if !tc.cleanedAfterFinish {
				finished = now.Add(-time.Hour)
			}
			a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: finished,
				CleanupAt: cleaned, CleanupResult: string(prev)}}
			if _, err := a.run(now); err != nil {
				t.Fatal(err)
			}
			if pruned := !exists(builds[0]); pruned != tc.wantPruned {
				t.Fatalf("pruned %v, want %v", pruned, tc.wantPruned)
			}
		})
	}
}

// TestAutoRun_ReadsTheLiveListPerSession (review round 4): the host's live
// list is read again right before each session's apply, so a terminal that
// went live after the pass began keeps its worktree.
func TestAutoRun_ReadsTheLiveListPerSession(t *testing.T) {
	t.Parallel()
	a := newAutoFixture(t)
	root := a.pushedWork("wt", "feat/x")
	a.record(root, "feat/x")
	a.endSession()
	a.store.activity[0].AgentCwd = root
	now := time.Now()
	broken := AutoCandidate{SessionID: 404, WorkbenchID: testWorkbench, FinishedAt: now} // no such row
	a.cands = []AutoCandidate{broken, {SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now}}
	calls := 0
	a.liveFn = func() (map[int64]bool, error) {
		calls++
		if calls == 1 {
			return map[int64]bool{}, nil
		}
		return map[int64]bool{testSession: true}, nil // its terminal went live
	}
	if _, err := a.run(now); err != nil {
		t.Fatal(err)
	}
	if calls != 2 || !a.listsWorktree(root) {
		t.Fatalf("live read %d times, worktree listed %v", calls, a.listsWorktree(root))
	}
}
