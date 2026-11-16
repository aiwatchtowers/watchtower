package sessioncleanup

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/gitbin"
)

// Source §2c of the auto cleanup spec (2026-11-10): the branches created in
// the session's own worktrees, read from git's HEAD logs. Real git; the
// reflog times are set through GIT_COMMITTER_DATE, never waited for.

// gitAt runs git in dir with its reflog and commit times at at.
func gitAt(t *testing.T, dir string, at time.Time, args ...string) {
	t.Helper()
	bin, _ := gitbin.Locate()
	c := exec.Command(bin, args...)
	c.Dir = dir
	stamp := fmt.Sprintf("@%d +0000", at.Unix())
	c.Env = append(os.Environ(), "GIT_COMMITTER_DATE="+stamp, "GIT_AUTHOR_DATE="+stamp)
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

// headLogPath is the HEAD log of the linked worktree at root.
func (f *fixture) headLogPath(root string) string {
	return filepath.Join(f.repo, ".git", "worktrees", filepath.Base(root), "logs", "HEAD")
}

// unreadable makes path unreadable until the test ends.
func unreadable(t *testing.T, path string) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root reads every file")
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
}

// sessionWorktree adds a worktree the session worked in (a cwd ledger row),
// created on branch from main with its reflog stamped at.
func (f *fixture) sessionWorktree(name, branch string, at time.Time) string {
	f.t.Helper()
	root := filepath.Join(f.base, name)
	gitAt(f.t, f.repo, at, "worktree", "add", "-q", "-b", branch, root, "main")
	f.record(root, branch)
	return root
}

func TestProj18_HeadLogBranchOnlyCheckedOutIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t) // the session started an hour ago
	t0 := time.Now().Add(-50 * time.Minute)
	gitAt(t, f.repo, t0.Add(-2*time.Hour), "branch", "other", "main") // older than the session
	wt2 := filepath.Join(f.base, "wt2")
	gitAt(t, f.repo, t0, "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")
	gitAt(t, wt2, t0.Add(time.Minute), "checkout", "-q", "-b", "late") // younger, made in another worktree
	gitAt(t, wt2, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt2")

	wt := f.sessionWorktree("wt", "feat/wt", t0.Add(5*time.Minute))
	gitAt(t, wt, t0.Add(6*time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(7*time.Minute), "checkout", "-q", "other")
	gitAt(t, wt, t0.Add(8*time.Minute), "checkout", "-q", "late")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+wt, ActionRemove, "")
	wantItem(t, p, "branch:mine", ActionRemove, "")
	wantItem(t, p, "branch:other", ActionKeep, ReasonNotThisSession)
	wantItem(t, p, "branch:late", ActionKeep, ReasonNotThisSession)
	if hasItem(p, "branch:main") {
		t.Fatalf("the default branch is a candidate: %+v", p.Items)
	}
}

// A branch created in the session's worktree that another worktree later
// switched to is not the session's.
func TestHeadLogBranchSwitchedToElsewhereIsNotOurs(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	wantItem(t, f.plan(Request{}), "branch:mine", ActionRemove, "")

	wt2 := filepath.Join(f.base, "wt2")
	gitAt(t, f.repo, t0.Add(3*time.Minute), "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")
	gitAt(t, wt2, t0.Add(4*time.Minute), "checkout", "-q", "mine")
	gitAt(t, wt2, t0.Add(5*time.Minute), "checkout", "-q", "feat/wt2")
	wantItem(t, f.plan(Request{}), "branch:mine", ActionKeep, ReasonNotThisSession)

	// The main worktree's log counts too.
	f2 := newFixture(t)
	wt = f2.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	gitAt(t, f2.repo, t0.Add(3*time.Minute), "checkout", "-q", "mine")
	gitAt(t, f2.repo, t0.Add(4*time.Minute), "checkout", "-q", "main")
	wantItem(t, f2.plan(Request{}), "branch:mine", ActionKeep, ReasonNotThisSession)
}

// Another worktree's HEAD log cannot be read: the session's created
// branches are kept as created_unknown, and the plan does not fail.
func TestHeadLogOtherLogUnreadableIsCreatedUnknown(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	wt2 := filepath.Join(f.base, "wt2")
	gitAt(t, f.repo, t0.Add(3*time.Minute), "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")
	unreadable(t, f.headLogPath(wt2))

	p := f.plan(Request{})
	wantItem(t, p, "branch:mine", ActionKeep, ReasonCreatedUnknown)
	// A branch the cwd ledger holds keeps its own standing.
	wantItem(t, p, "branch:feat/wt", ActionRemove, "")
}

// The session's own worktree's HEAD log exists but cannot be read: the
// plan fails rather than say there is nothing to clean.
func TestHeadLogOwnLogUnreadableFailsPlan(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	wt := f.sessionWorktree("wt", "feat/wt", time.Now().Add(-50*time.Minute))
	unreadable(t, f.headLogPath(wt))
	if res, err := PlanResult(context.Background(), f.deps(), Request{SessionID: testSession}); err == nil {
		t.Fatalf("PlanResult = %+v, want an error", res.Plan.Items)
	}
}

// §2c reads only git: a Codex row gets it as a Claude row does.
func TestHeadLogWorksForCodexRows(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	f.store.session.Kind = "codex"
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "switch", "-q", "-c", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "switch", "-q", "feat/wt")

	p := f.plan(Request{})
	wantItem(t, p, "branch:mine", ActionRemove, "")
	wantNote(t, p, false)
}

// A worktree the session only visited (born before it started) is not
// read: what was created there is not the session's.
func TestHeadLogOfAWorktreeOlderThanTheSessionNamesNothing(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	f.sessionCreated = time.Now().Add(time.Hour)

	if hasItem(f.plan(Request{}), "branch:mine") {
		t.Fatal("a branch of a worktree older than the session is a candidate")
	}
}
