package workbenchcheck

import (
	"context"
	"strings"
	"testing"
)

// newFeatureRepo builds main and a feature branch "feature" with one commit
// of its own, and these leaf branches cut from feature:
//
//	wt/merge  — one commit, merged into feature with a merge commit
//	wt/ff     — one commit, merged into feature by a fast-forward
//	wt/squash — two commits, squashed into one commit on feature
//	wt/fresh  — cut from feature's tip, no commits of its own
//	wt/open   — one commit feature lacks
func newFeatureRepo(t *testing.T) string {
	t.Helper()
	gitEnv(t)
	dir := t.TempDir()
	gitRun(t, dir, "init", "-q", "-b", "main")
	commitFile(t, dir, "README.md", "hello\n", "init")
	gitRun(t, dir, "checkout", "-q", "-b", "feature")
	commitFile(t, dir, "feature.txt", "f\n", "feature")

	gitRun(t, dir, "checkout", "-q", "-b", "wt/ff")
	commitFile(t, dir, "ff.txt", "ff\n", "ff")
	gitRun(t, dir, "checkout", "-q", "feature")
	gitRun(t, dir, "merge", "-q", "--ff-only", "wt/ff")

	gitRun(t, dir, "checkout", "-q", "-b", "wt/merge")
	commitFile(t, dir, "m.txt", "m\n", "m")
	gitRun(t, dir, "checkout", "-q", "feature")
	commitFile(t, dir, "feature2.txt", "f2\n", "feature moves on")
	gitRun(t, dir, "merge", "-q", "--no-ff", "-m", "merge m", "wt/merge")

	gitRun(t, dir, "checkout", "-q", "-b", "wt/squash")
	commitFile(t, dir, "s.txt", "s1\n", "s1")
	commitFile(t, dir, "s.txt", "s1\ns2\n", "s2")
	gitRun(t, dir, "checkout", "-q", "feature")
	gitRun(t, dir, "merge", "-q", "--squash", "wt/squash")
	gitRun(t, dir, "commit", "-q", "-m", "squash s")

	gitRun(t, dir, "checkout", "-q", "-b", "wt/open")
	commitFile(t, dir, "o.txt", "o\n", "o")
	gitRun(t, dir, "checkout", "-q", "feature")
	gitRun(t, dir, "branch", "wt/fresh")
	gitRun(t, dir, "checkout", "-q", "main")
	return dir
}

func TestOpenRepositoryAgainst_MergeIntoAFeatureBranch(t *testing.T) {
	dir := newFeatureRepo(t)
	ctx := context.Background()
	repo := OpenRepositoryAgainst(ctx, dir, "feature", nil)
	if len(repo.Notes()) != 0 {
		t.Fatalf("notes %v, want none", repo.Notes())
	}
	for branch, want := range map[string]BranchMerge{
		"wt/merge":  BranchMerged,
		"wt/ff":     BranchMerged,
		"wt/squash": BranchMerged,
		"wt/fresh":  BranchNotMerged, // cut from the base, no work of its own
		"wt/open":   BranchNotMerged,
		"wt/gone":   BranchMissing,
		"feature":   BranchUnknown, // the base itself
		"":          BranchUnknown,
	} {
		if got := repo.BranchMerge(ctx, branch); got != want {
			t.Errorf("%q into feature: %v, want %v", branch, got, want)
		}
	}
	// Against the default branch none of the leaves is merged.
	def := OpenRepository(ctx, dir, nil)
	for _, branch := range []string{"wt/merge", "wt/ff", "wt/squash"} {
		if got := def.BranchMerge(ctx, branch); got != BranchNotMerged {
			t.Errorf("%q into main: %v, want not merged", branch, got)
		}
	}
}

func TestOpenRepositoryAgainst_MissingBaseIsANote(t *testing.T) {
	dir := newFeatureRepo(t)
	ctx := context.Background()
	repo := OpenRepositoryAgainst(ctx, dir, "nope", nil)
	if got := repo.BranchMerge(ctx, "wt/merge"); got != BranchUnknown {
		t.Fatalf("merge into a missing base: %v, want unknown", got)
	}
	if notes := strings.Join(repo.Notes(), "; "); !strings.Contains(notes, "nope") {
		t.Fatalf("notes %q, want the missing base named", notes)
	}
}

func TestOpenRepositoryAgainst_OriginOnlyBase(t *testing.T) {
	dir := newFeatureRepo(t)
	gitRun(t, dir, "update-ref", "refs/remotes/origin/feature", "feature")
	gitRun(t, dir, "branch", "-q", "-D", "feature")
	ctx := context.Background()
	repo := OpenRepositoryAgainst(ctx, dir, "feature", nil)
	if got := repo.BranchMerge(ctx, "wt/merge"); got != BranchMerged {
		t.Fatalf("merge into origin/feature: %v, want merged", got)
	}
}

// A branch left only on origin whose tip the base contains: a fast-forward
// merge and a commit-less push look the same, and BranchMerge says not
// merged; OriginOnlyContained flags the guess.
func TestOpenRepositoryAgainst_OriginOnlyContained(t *testing.T) {
	dir := newFeatureRepo(t)
	gitRun(t, dir, "update-ref", "refs/remotes/origin/wt/ff", "wt/ff")
	gitRun(t, dir, "branch", "-q", "-D", "wt/ff")
	gitRun(t, dir, "update-ref", "refs/remotes/origin/wt/open", "wt/open")
	gitRun(t, dir, "branch", "-q", "-D", "wt/open")
	ctx := context.Background()
	repo := OpenRepositoryAgainst(ctx, dir, "feature", nil)
	if got := repo.BranchMerge(ctx, "wt/ff"); got != BranchNotMerged {
		t.Fatalf("origin-only fast-forward: %v, want not merged (no reflog)", got)
	}
	if !repo.OriginOnlyContained(ctx, "wt/ff") {
		t.Fatal("origin-only contained tip not flagged")
	}
	if repo.OriginOnlyContained(ctx, "wt/open") || repo.OriginOnlyContained(ctx, "wt/merge") ||
		repo.OriginOnlyContained(ctx, "feature") {
		t.Fatal("flagged a tip with own work, a local branch or the base")
	}
}
