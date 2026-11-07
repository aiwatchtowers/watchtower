package reviewdiff

import (
	"context"
	"strings"
	"testing"
)

func TestHeadBranch(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	ctx := context.Background()
	if got, err := r.HeadBranch(ctx); err != nil || got != "main" {
		t.Fatalf("HeadBranch = %q, %v; want main", got, err)
	}
	gitIn(t, dir, "checkout", "-q", "--detach")
	if got, err := r.HeadBranch(ctx); err != nil || got != "" {
		t.Fatalf("detached HeadBranch = %q, %v; want empty", got, err)
	}
}

func TestBranch_LocalThenOriginThenMissing(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "checkout", "-q", "-b", "feature/x")
	writeFile(t, dir, "b.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "b")
	tipCommit := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	tipTree := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD^{tree}"))
	gitIn(t, dir, "checkout", "-q", "main")
	r := openRepo(t, dir)
	ctx := context.Background()

	tip, ok, err := r.Branch(ctx, "feature/x")
	if err != nil || !ok {
		t.Fatalf("Branch local = %v, %v", ok, err)
	}
	if tip.Ref != "refs/heads/feature/x" || tip.Commit != tipCommit || tip.Tree != tipTree {
		t.Fatalf("tip = %+v", tip)
	}

	// Only on origin: the remote-tracking ref is found.
	gitIn(t, dir, "update-ref", "refs/remotes/origin/feature/y", tipCommit)
	tip, ok, err = r.Branch(ctx, "feature/y")
	if err != nil || !ok || tip.Ref != "refs/remotes/origin/feature/y" {
		t.Fatalf("Branch origin = %+v, %v, %v", tip, ok, err)
	}

	for _, name := range []string{"nope", "", "--all"} {
		if _, ok, err := r.Branch(ctx, name); err != nil || ok {
			t.Fatalf("Branch(%q) = %v, %v; want missing", name, ok, err)
		}
	}
}

func TestBranchBase_AncestorBranchElseDefault(t *testing.T) {
	dir := newRepo(t)
	mainCommit := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	gitIn(t, dir, "checkout", "-q", "-b", "feature")
	writeFile(t, dir, "f.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "f")
	featureCommit := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	gitIn(t, dir, "checkout", "-q", "-b", "feature-task")
	writeFile(t, dir, "t.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "t")
	gitIn(t, dir, "checkout", "-q", "main")
	r := openRepo(t, dir)
	ctx := context.Background()
	tip, ok, err := r.Branch(ctx, "feature-task")
	if err != nil || !ok {
		t.Fatal(ok, err)
	}

	base, err := r.BranchBase(ctx, tip, "feature")
	if err != nil || base.SHA != featureCommit || base.Label != "feature" {
		t.Fatalf("base on the ancestor branch = %+v, %v", base, err)
	}
	base, err = r.BranchBase(ctx, tip, "")
	if err != nil || base.SHA != mainCommit || base.Label != "main" {
		t.Fatalf("base on the default branch = %+v, %v", base, err)
	}
	// An ancestor branch that exists nowhere falls back to the default branch.
	base, err = r.BranchBase(ctx, tip, "gone")
	if err != nil || base.SHA != mainCommit || base.Label != "main" {
		t.Fatalf("base for a missing ancestor branch = %+v, %v", base, err)
	}
}
