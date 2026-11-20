package sessioncleanup

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestApply_TakesTheWorkbenchLockFirst: an apply takes Deps.Lock for the
// session's workbench (read from the session when the request names none)
// and holds it to its end; a lock that cannot be taken fails the apply
// before anything is evaluated or removed.
func TestApply_TakesTheWorkbenchLockFirst(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")

	refused := errors.New("held elsewhere")
	d := f.deps()
	d.Lock = func(context.Context, int64) (func(), error) { return nil, refused }
	if _, err := Apply(context.Background(), d, Request{SessionID: testSession}, nil); !errors.Is(err, refused) {
		t.Fatalf("err = %v, want the lock's", err)
	}
	if !exists(root) {
		t.Fatal("removed without the lock")
	}

	var locked []int64
	held := false
	d.Lock = func(_ context.Context, id int64) (func(), error) {
		locked, held = append(locked, id), true
		return func() { held = false }, nil
	}
	d.Git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		if !held {
			t.Errorf("git %s ran without the lock", strings.Join(args, " "))
		}
		return nil
	}}
	res, err := Apply(context.Background(), d, Request{SessionID: testSession}, nil)
	if err != nil {
		t.Fatal(err)
	}
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	if len(locked) != 1 || locked[0] != testWorkbench || held {
		t.Fatalf("locked %v, still held %v", locked, held)
	}
}

// autoFixture is a fixture with the automatic pass's seams.
type autoFixture struct {
	*fixture
	cands   []AutoCandidate
	live    map[int64]bool
	liveErr error
	busy    bool
	locked  []int64
	results *fakeResults
}

func newAutoFixture(t *testing.T) *autoFixture {
	t.Helper()
	return &autoFixture{fixture: newFixture(t), live: map[int64]bool{}, results: &fakeResults{}}
}

func (a *autoFixture) run(now time.Time) (AutoResult, error) {
	a.t.Helper()
	d := a.deps()
	d.Results = a.results
	d.Lock = func(context.Context, int64) (func(), error) {
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
		TryLock: func(id int64) (func(), bool, error) {
			if a.busy {
				return nil, false, nil
			}
			a.locked = append(a.locked, id)
			return func() {}, true, nil
		},
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
	if len(a.locked) != 1 || a.locked[0] != testWorkbench || a.results.sessionID != testSession {
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
// left work that may still go.
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
		TryLock: func(int64) (func(), bool, error) {
			t.Error("a cancelled pass took a lock")
			return func() {}, true, nil
		},
	}, time.Now())
	if !errors.Is(err, context.Canceled) || res != (AutoResult{}) {
		t.Fatalf("res %+v, err %v", res, err)
	}
}
