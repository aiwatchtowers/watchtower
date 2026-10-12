package sessioncleanup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A session whose start is unknown (zero) owns nothing: every worktree and
// branch it saw is kept, however young.
func TestPlan_UnknownSessionStartKeepsEverything(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	gitIn(t, f.repo, "branch", "feat/merged", "main")
	f.record(f.repo, "feat/merged")
	f.sessionCreated = time.Time{}

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionKeep, ReasonCreatedUnknown)
	wantItem(t, p, "branch:feat/merged", ActionKeep, ReasonCreatedUnknown)
	wantItem(t, p, "branch:feat/x", ActionKeep, ReasonCheckedOut)
}

// Neither time is truncated: an item born a fraction of a second before the
// session start, within the same second, existed before the session.
func TestBornReason_SubSecondBeforeTheStartIsNotOwned(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 10, 12, 12, 0, 0, 800_000_000, time.UTC)
	cases := []struct {
		birth time.Time
		want  string
	}{
		{start.Add(-300 * time.Millisecond), ReasonExistedBeforeSession},
		{start.Add(-time.Nanosecond), ReasonExistedBeforeSession},
		{start, ""},
		{start.Add(100 * time.Millisecond), ""},
	}
	for _, tc := range cases {
		if got := bornReason(tc.birth, true, start); got != tc.want {
			t.Errorf("born %v vs start %v = %q, want %q", tc.birth, start, got, tc.want)
		}
	}
	if got := bornReason(start.Add(time.Hour), true, time.Time{}); got != ReasonCreatedUnknown {
		t.Errorf("zero session start = %q, want %q", got, ReasonCreatedUnknown)
	}
}

// With no origin/HEAD, main or master the default branch is unknown: every
// branch is kept, even a pushed one the session created.
func TestProj16_UnknownDefaultBranchKeepsEveryBranch(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gitIn(t, f.repo, "branch", "-m", "main", "develop")
	gitIn(t, f.repo, "remote", "set-head", "origin", "-d")
	gitIn(t, f.repo, "branch", "feat/x", "develop")
	gitIn(t, f.repo, "push", "-q", "origin", "feat/x")
	f.record(f.repo, "feat/x")

	p := f.plan(Request{DeclaredBranches: []string{"develop"}})
	if p.DefaultBranch != "" {
		t.Fatalf("default branch = %q, want unknown", p.DefaultBranch)
	}
	wantItem(t, p, "branch:feat/x", ActionKeep, ReasonDefaultBranchUnknown)
	wantItem(t, p, "branch:develop", ActionKeep, ReasonDefaultBranchUnknown)
	for _, it := range f.plan(Request{Sweep: true}).Items {
		if it.Kind == KindBranch && it.Action != ActionKeep {
			t.Fatalf("the sweep removes %s with the default branch unknown", it.Key)
		}
	}
}

// A symbolic-ref failure other than "not a symbolic ref" is not read as
// "no origin/HEAD": the default branch is unknown and the error is shown.
func TestProj16_OriginHeadReadFailureKeepsEveryBranch(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gitIn(t, f.repo, "branch", "feat/merged", "main")
	f.record(f.repo, "feat/merged")
	f.git = failGitOn("symbolic-ref")

	it := wantItem(t, f.plan(Request{}), "branch:feat/merged", ActionKeep, ReasonDefaultBranchUnknown)
	if !strings.Contains(it.Detail, "injected failure") {
		t.Fatalf("detail = %q, want the git error", it.Detail)
	}
}

// detachedGone adds a detached worktree with one commit of its own (pushed
// or not), records it and deletes its directory: git lists it as prunable.
func (f *fixture) detachedGone(name string, push bool) string {
	f.t.Helper()
	root := filepath.Join(f.base, name)
	gitIn(f.t, f.repo, "worktree", "add", "-q", "--detach", root, "main")
	f.commit(root, name+".txt", "work\n")
	if push {
		gitIn(f.t, root, "push", "-q", "origin", "HEAD:refs/heads/"+name)
	}
	f.record(root, "")
	if err := os.RemoveAll(root); err != nil {
		f.t.Fatal(err)
	}
	return root
}

// Pruning a detached worktree whose directory is gone drops the only ref
// to its unpushed commit, so the worktree is kept.
func TestProj16_PrunableDetachedWorktreeWithUnpushedCommitIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	unpushed := f.detachedGone("wt-unpushed", false)
	pushed := f.detachedGone("wt-pushed", true)

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+unpushed, ActionKeep, ReasonUnpushedCommits)
	if it := wantItem(t, p, "worktree:"+pushed, ActionRemove, ""); it.Detail != detailGone {
		t.Fatalf("pushed prunable item = %+v", it)
	}
}

func TestProj16_PrunableWorktreeWithUnreadableHeadIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.detachedGone("wt", true)
	admin := filepath.Join(f.repo, ".git", "worktrees", "wt")
	writeFile(t, filepath.Join(admin, "HEAD"), "ref: refs/heads/feat/never-created\n")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)

	f.git = failGitOn("for-each-ref", "--count=1")
	writeFile(t, filepath.Join(admin, "HEAD"), gitIn(t, f.repo, "rev-parse", "refs/remotes/origin/wt")+"\n")
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)
}
