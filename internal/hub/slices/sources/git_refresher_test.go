package sources

import (
	"context"
	"errors"
	"os"
	osexec "os/exec"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/workbenchgit"
)

// Go twins of WorkbenchSliceTests' git refresher tests and the refresher
// half of HubRunnerWakeTests (the wait after each pass).

type gitRig struct {
	t     *testing.T
	d     *db.DB
	mu    sync.Mutex
	now   time.Time
	calls []int64
	fetch func(id int64) (workbenchgit.Status, error)
}

func newGitRig(t *testing.T) *gitRig {
	return &gitRig{t: t, d: db.OpenTestDB(t), now: time.Unix(1_800_000_000, 0)}
}

func (r *gitRig) clock() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.now
}

func (r *gitRig) advance(d time.Duration) {
	r.mu.Lock()
	r.now = r.now.Add(d)
	r.mu.Unlock()
}

func (r *gitRig) callCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.calls)
}

func okStatus(branch string, detached bool, changes int) workbenchgit.Status {
	st := workbenchgit.Status{StatusOK: true, Git: true, GitAvailable: true}
	st.Branch, st.Detached, st.Changes = branch, detached, changes
	return st
}

func (r *gitRig) refresher(timing GitTiming) *GitRefresher {
	return NewGitRefresher(r.d, GitRefresherOptions{
		Timing: timing,
		Fetch: func(_ context.Context, id int64) (workbenchgit.Status, error) {
			r.mu.Lock()
			r.calls = append(r.calls, id)
			fetch := r.fetch
			r.mu.Unlock()
			if fetch != nil {
				return fetch(id)
			}
			return okStatus("main", false, 0), nil
		},
		Now: r.clock,
	})
}

func TestGitRefresherDetachedHasNoBranch(t *testing.T) {
	r := newGitRig(t)
	wb := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	r.fetch = func(int64) (workbenchgit.Status, error) { return okStatus("abc1234", true, 2), nil }
	g := r.refresher(GitTiming{})
	g.RefreshDue(context.Background())
	if s, ok := g.Status(wb); !ok || s != (GitSnapshot{Branch: "", Detached: true, Changes: 2}) {
		t.Fatalf("Status = %+v, %v", s, ok)
	}
}

func TestGitRefresherFailureRefusalAndHangKeepTheLastValue(t *testing.T) {
	r := newGitRig(t)
	wb := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	g := r.refresher(GitTiming{Every: 120 * time.Second, MinSpacing: 30 * time.Second, Timeout: 50 * time.Millisecond, Idle: 15 * time.Second})
	r.fetch = func(int64) (workbenchgit.Status, error) { return okStatus("feature/acme", false, 1), nil }
	ctx := context.Background()
	g.RefreshDue(ctx)

	r.fetch = func(int64) (workbenchgit.Status, error) { return workbenchgit.Status{}, errors.New("git missing") }
	r.advance(120 * time.Second)
	if got := g.RefreshDue(ctx); !slices.Equal(got, []int64{wb}) {
		t.Fatalf("attempted %v", got)
	}
	if s, _ := g.Status(wb); s.Branch != "feature/acme" {
		t.Fatalf("a failed read replaced the value: %+v", s)
	}

	r.fetch = func(int64) (workbenchgit.Status, error) {
		st := okStatus("", false, 4)
		st.StatusOK = false
		return st, nil
	}
	r.advance(120 * time.Second)
	g.RefreshDue(ctx)
	if s, _ := g.Status(wb); s.Branch != "feature/acme" || s.Changes != 1 {
		t.Fatalf("a status git could not read replaced the value: %+v", s)
	}

	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	r.fetch = func(int64) (workbenchgit.Status, error) {
		<-block
		return okStatus("hung", false, 9), nil
	}
	r.advance(120 * time.Second)
	g.RefreshDue(ctx)
	if s, _ := g.Status(wb); s.Branch != "feature/acme" {
		t.Fatalf("a hung read replaced the value: %+v", s)
	}
}

func TestGitRefresherCadenceIsEvery120SecondsPerWorkbench(t *testing.T) {
	r := newGitRig(t)
	insertWorkbench(t, r.d, "acme", "/tmp/acme")
	g := r.refresher(GitTiming{})
	ctx := context.Background()
	g.RefreshDue(ctx)
	r.advance(119 * time.Second)
	g.RefreshDue(ctx)
	if r.callCount() != 1 {
		t.Fatal("due before 120 s")
	}
	r.advance(time.Second)
	g.RefreshDue(ctx)
	if r.callCount() != 2 {
		t.Fatal("not due at 120 s")
	}
	if StandardGitTiming != (GitTiming{Every: 120 * time.Second, MinSpacing: 30 * time.Second, Timeout: 20 * time.Second, Idle: 15 * time.Second}) {
		t.Fatalf("standard timing %+v", StandardGitTiming)
	}
}

func TestGitRefresherASessionStateChangeRefreshesAtMostOncePer30Seconds(t *testing.T) {
	r := newGitRig(t)
	wb := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	g := r.refresher(GitTiming{})
	ctx := context.Background()
	g.RefreshDue(ctx)
	if w := g.c.nextWait(r.clock(), StandardGitTiming.Idle); w != 15*time.Second {
		t.Fatalf("with no change the loop waits idle, got %v", w)
	}

	r.advance(22 * time.Second)
	g.SessionStateChanged(wb)
	g.RefreshDue(ctx)
	if r.callCount() != 1 {
		t.Fatal("a change 22 s after a run did not wait for the 30 s spacing")
	}
	if w := g.c.nextWait(r.clock(), StandardGitTiming.Idle); w != 8*time.Second {
		t.Fatalf("the loop waits only the rest of the spacing: %v, want 8s", w)
	}
	r.advance(8 * time.Second)
	g.RefreshDue(ctx)
	if r.callCount() != 2 {
		t.Fatal("the held change did not run at 30 s")
	}

	g.SessionStateChanged(wb)
	g.SessionStateChanged(wb)
	r.advance(30 * time.Second)
	g.RefreshDue(ctx)
	g.RefreshDue(ctx)
	if r.callCount() != 3 {
		t.Fatalf("two changes in one spacing: %d runs", r.callCount())
	}

	g.SessionStateChanged(99)
	r.advance(30 * time.Second)
	g.RefreshDue(ctx)
	if r.callCount() != 3 {
		t.Fatal("a change on an unknown workbench ran something")
	}
}

func TestGitRefresherForgetsAWorkbenchThatLeftAndRestoresACutPass(t *testing.T) {
	r := newGitRig(t)
	a := insertWorkbench(t, r.d, "a", "/tmp/a")
	b := insertWorkbench(t, r.d, "b", "/tmp/b")
	g := r.refresher(GitTiming{})
	ctx, cancel := context.WithCancel(context.Background())
	// The first read cancels the pass (the hub stopped): nothing is stored
	// and both workbenches stay due.
	r.fetch = func(int64) (workbenchgit.Status, error) {
		cancel()
		return okStatus("main", false, 0), nil
	}
	g.RefreshDue(ctx)
	if _, ok := g.Status(a); ok {
		t.Fatal("the cut read stored a value")
	}
	r.fetch = nil
	got := g.RefreshDue(context.Background())
	slices.Sort(got)
	if !slices.Equal(got, []int64{a, b}) {
		t.Fatalf("after the cut pass %v ran, want both", got)
	}

	exec(t, r.d, `DELETE FROM projects WHERE id = ?`, b)
	g.RefreshDue(context.Background())
	if _, ok := g.Status(b); ok {
		t.Fatal("a removed workbench kept its status")
	}
}

func TestGitRefresherWithoutAPhoneReadsNothing(t *testing.T) {
	r := newGitRig(t)
	insertWorkbench(t, r.d, "acme", "/tmp/acme")
	g := NewGitRefresher(r.d, GitRefresherOptions{
		Timing: GitTiming{Every: time.Minute, MinSpacing: time.Second, Timeout: time.Second, Idle: 5 * time.Millisecond},
		Fetch: func(context.Context, int64) (workbenchgit.Status, error) {
			r.mu.Lock()
			r.calls = append(r.calls, 0)
			r.mu.Unlock()
			return okStatus("main", false, 0), nil
		},
		Active: func() bool { return false },
	})
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	_ = g.Run(ctx)
	if r.callCount() != 0 {
		t.Fatal("the refresher read git with no phone linked")
	}
}

// The default fetch reads the folder's status in-process.
func TestGitRefresherInProcessStatus(t *testing.T) {
	gitPath, err := osexec.LookPath("git")
	if err != nil {
		t.Skip("git not installed")
	}
	folder := t.TempDir()
	for _, args := range [][]string{{"init", "-q", "-b", "trunk"}, {"config", "user.email", "dev@example.com"}, {"config", "user.name", "Dev"}} {
		c := osexec.Command(gitPath, args...)
		c.Dir = folder
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(folder, "a.txt"), []byte("a"), 0o600); err != nil {
		t.Fatal(err)
	}
	d := db.OpenTestDB(t)
	wb := insertWorkbench(t, d, "acme", folder)
	g := NewGitRefresher(d, GitRefresherOptions{})
	g.RefreshDue(context.Background())
	s, ok := g.Status(wb)
	if !ok || s.Branch != "trunk" || s.Changes != 1 || s.Detached {
		t.Fatalf("Status = %+v, %v", s, ok)
	}
}

// OnChange fires when a workbench's stored status is new or differs, never
// for an unchanged read or a failed one.
func TestGitRefresherOnChangeOnlyWhenTheStatusChanged(t *testing.T) {
	r := newGitRig(t)
	insertWorkbench(t, r.d, "acme", "/tmp/acme")
	changes := 0
	g := r.refresher(GitTiming{Every: 120 * time.Second, MinSpacing: 30 * time.Second, Timeout: time.Second, Idle: 15 * time.Second})
	g.o.OnChange = func() { changes++ }
	ctx := context.Background()
	step := func(want int) {
		t.Helper()
		g.RefreshDue(ctx)
		r.advance(120 * time.Second)
		if changes != want {
			t.Fatalf("OnChange %d times, want %d", changes, want)
		}
	}
	step(1) // the first value
	step(1) // unchanged
	r.fetch = func(int64) (workbenchgit.Status, error) { return okStatus("main", false, 3), nil }
	step(2)
	r.fetch = func(int64) (workbenchgit.Status, error) { return workbenchgit.Status{}, errors.New("git missing") }
	step(2)
}
