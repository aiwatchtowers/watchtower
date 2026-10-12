package sessioncleanup

import (
	"os"
	"path/filepath"
	"strconv"
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

// The stored session start has second precision (created_at is written by
// strftime('%Y-%m-%dT%H:%M:%SZ')), so the real start may be up to a second
// later: an item born within that second is not the session's.
func TestBornReason_WithinTheStoredStartSecondIsNotOwned(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		birth time.Time
		want  string
	}{
		{start.Add(-300 * time.Millisecond), ReasonExistedBeforeSession},
		{start, ReasonExistedBeforeSession},
		{start.Add(500 * time.Millisecond), ReasonExistedBeforeSession},
		{start.Add(time.Second - time.Nanosecond), ReasonExistedBeforeSession},
		{start.Add(time.Second), ""},
		{start.Add(2 * time.Second), ""},
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

// W6 sees the sessions of every workbench: an agent of a second workbench
// over the same repository working inside the worktree keeps it, and so
// does the caller when its session belongs to another workbench.
func TestProj16_SessionOfAnotherWorkbenchInTheWorktreeKeepsIt(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	other := SessionActivity{ID: 91, WorkbenchID: testWorkbench + 1, Title: "other workbench",
		AgentCwd: filepath.Join(root, "sub"), ReportedAt: time.Now().Add(-time.Minute)}
	f.store.activity = []SessionActivity{other}

	if it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonSessionInIt); it.Detail != other.Title {
		t.Fatalf("detail = %q", it.Detail)
	}
	wantItem(t, f.plan(Request{Sweep: true}), "worktree:"+root, ActionKeep, ReasonSessionInIt)
	wantItem(t, f.plan(Request{CallerSessionID: other.ID}), "worktree:"+root, ActionKeep, ReasonYouAreInIt)
}

// After reflog expiry the oldest remaining entry is some later update, not
// the creation: the branch's birth is unknown and it is kept.
func TestProj16_BranchWhoseCreationEntryExpiredIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gitIn(t, f.repo, "branch", "feat/old", "main")
	f.record(f.repo, "feat/old")
	sha := gitIn(t, f.repo, "rev-parse", "main")
	line := sha + " " + sha + " Test <test@example.com> " + strconv.FormatInt(time.Now().Unix(), 10) +
		" +0000\treset: moving to main\n"
	writeFile(t, filepath.Join(f.repo, ".git", "logs", "refs", "heads", "feat", "old"), line)

	wantItem(t, f.plan(Request{}), "branch:feat/old", ActionKeep, ReasonCreatedUnknown)
}

func TestReflogCreation(t *testing.T) {
	t.Parallel()
	const zero, a, b = "0000000000000000000000000000000000000000", "1111111111111111111111111111111111111111",
		"2222222222222222222222222222222222222222"
	cases := []struct {
		line string
		want bool
	}{
		{zero + " " + a + " T <t@example.com> 1791800000 +0200\tbranch: Created from main\n", true},
		{zero + " " + a + " T <t@example.com> 1791800000 +0200\tcommit (initial): a\n", true},
		{zero + " " + a + " T <t@example.com> 1791800000 +0200\tfetch origin x:x: storing head\n", true},
		{b + " " + a + " T <t@example.com> 1791800000 +0200\tbranch: Created from HEAD\n", true},
		{b + " " + a + " T <t@example.com> 1791800000 +0200\tcommit: later work\n", false},
		{b + " " + a + " T <t@example.com> 1791800000 +0200\treset: moving to main\n", false},
		{zero + " " + a + " T <t@example.com> notatime +0200\tbranch: Created from main\n", false},
		{"garbage\n", false},
	}
	for _, tc := range cases {
		at, ok := reflogCreation(tc.line)
		if ok != tc.want {
			t.Errorf("reflogCreation(%q) = %v, want %v", tc.line, ok, tc.want)
		}
		if ok && at.Unix() != 1791800000 {
			t.Errorf("reflogCreation(%q) time = %v", tc.line, at)
		}
	}
}

// A worktree added under worktree.useRelativePaths has a relative gitdir
// file: it resolves against the admin dir, so the worktree's birth is known.
func TestPlan_RelativeGitdirResolvesAgainstTheAdminDir(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := filepath.Join(f.base, "wt-rel")
	gitIn(t, f.repo, "-c", "worktree.useRelativePaths=true", "worktree", "add", "-q", "-b", "feat/rel", root, "main")
	gitdir, err := os.ReadFile(filepath.Join(f.repo, ".git", "worktrees", "wt-rel", "gitdir"))
	if err != nil {
		t.Fatal(err)
	}
	if filepath.IsAbs(strings.TrimSpace(string(gitdir))) {
		t.Skip("this git writes no relative gitdir")
	}
	f.commit(root, "rel.txt", "work\n")
	gitIn(t, root, "push", "-q", "origin", "feat/rel")
	f.record(root, "feat/rel")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
}

// A git failure inside a catch keeps the item as check_failed with git's
// error in the detail: W4 (status), W7 (ancestry, remote containment) and
// B4 (the branch's tip).
func TestProj16_GitFailureInACatchKeepsTheItem(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		failOn []string
		key    func(root string) string
	}{
		{"W4 status", []string{"status"}, func(root string) string { return "worktree:" + root }},
		{"W7 merge-base", []string{"merge-base"}, func(root string) string { return "worktree:" + root }},
		{"W7 remote refs", []string{"for-each-ref", "--count=1"}, func(root string) string { return "worktree:" + root }},
		{"B4 merge-base", []string{"merge-base"}, func(string) string { return "branch:feat/merged" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root := f.pushedWork("wt", "feat/x")
			f.record(root, "feat/x")
			gitIn(t, f.repo, "branch", "feat/merged", "main")
			f.record(f.repo, "feat/merged")
			p := f.plan(Request{})
			wantItem(t, p, "worktree:"+root, ActionRemove, "")
			wantItem(t, p, "branch:feat/merged", ActionRemove, "")

			f.git = failGitOn(tc.failOn...)
			it := wantItem(t, f.plan(Request{}), tc.key(root), ActionKeep, ReasonCheckFailed)
			if !strings.Contains(it.Detail, "injected failure") {
				t.Fatalf("detail = %q, want the git error", it.Detail)
			}
		})
	}
}
