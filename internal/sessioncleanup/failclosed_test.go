package sessioncleanup

import (
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
