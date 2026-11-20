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
		keys, err := lockKeys(context.Background(), f.deps(), r)
		if err != nil || len(keys) != 1 || keys[0] != repo {
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
		Live: func(context.Context) (map[int64]bool, error) { return a.live, a.liveErr },
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

// TestAutoRun_SkipsBusyAndFailsClosedOnLive: a workbench whose lock is held
// is skipped this pass; a live list that cannot be read stops the pass
// before anything is applied.
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
	if _, err := a.run(now); err == nil {
		t.Fatal("no error without the live list")
	}
	if !exists(root) || len(a.locked) != 0 {
		t.Fatal("something was applied")
	}
}

// TestAutoDue: never cleaned, or cleaned before the finish → due; cleaned
// after the finish → due only autoRetry later and only while the result
// left work that may still go — a worktree kept only for uncommitted
// changes whose builds were checked, and a branch only checked out, are
// not (review F6).
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
