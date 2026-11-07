package reviewdiff

import (
	"context"
	"errors"
	"slices"
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
	// A tag named like the branch never turns the name into "heads/main".
	gitIn(t, dir, "checkout", "-q", "main")
	gitIn(t, dir, "tag", "main")
	if got, err := r.HeadBranch(ctx); err != nil || got != "main" {
		t.Fatalf("HeadBranch with a same-named tag = %q, %v; want main", got, err)
	}
}

// failingGit runs real git, except that a call whose arguments include every
// word of match exits 128 instead (a broken repository, a lock, a bad object).
func failingGit(t *testing.T, match ...string) Runner {
	t.Helper()
	return func(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error) {
		hit := true
		for _, m := range match {
			hit = hit && slices.Contains(args, m)
		}
		if hit {
			return nil, &GitExitError{Subcommand: subcommand(args), Code: 128, Stderr: "fatal: broken"}
		}
		return execRunner(ctx, dir, env, name, args...)
	}
}

func openFailing(t *testing.T, dir string, match ...string) *Repo {
	t.Helper()
	gitBin(t)
	r, err := Open(dir, failingGit(t, match...))
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// Only git's documented "no" (exit 1) reads as detached, missing or no base;
// any other exit is an error, never a quiet fallback.
func TestBranchReads_OtherGitFailuresAreErrors(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "branch", "feature")
	ctx := context.Background()
	var exit *GitExitError

	if _, err := openFailing(t, dir, "symbolic-ref", "HEAD").HeadBranch(ctx); !errors.As(err, &exit) || exit.Code != 128 {
		t.Fatalf("HeadBranch on exit 128 = %v; want the git error", err)
	}
	if _, ok, err := openFailing(t, dir, "rev-parse").Branch(ctx, "feature"); err == nil || ok {
		t.Fatalf("Branch on exit 128 = %v, %v; want the git error", ok, err)
	}
	tip, ok, err := openRepo(t, dir).Branch(ctx, "feature")
	if err != nil || !ok {
		t.Fatal(ok, err)
	}
	if _, err := openFailing(t, dir, "merge-base").BranchBase(ctx, tip, ""); err == nil {
		t.Fatal("BranchBase on a failing merge-base answered")
	}
	if _, err := openFailing(t, dir, "merge-base").Base(ctx); err == nil {
		t.Fatal("Base on a failing merge-base answered")
	}
	headFails := openFailing(t, dir, "HEAD^{commit}")
	if _, err := headFails.Base(ctx); !errors.As(err, &exit) || exit.Code != 128 {
		t.Fatalf("Base on a failing HEAD read = %v; want the git error, not the empty tree", err)
	}
	if _, err := headFails.HeadBase(ctx, "feature"); err == nil {
		t.Fatal("HeadBase on a failing HEAD read answered")
	}
	// An unborn HEAD (git's exit 1) is still "no commit": the empty tree.
	unborn := t.TempDir()
	gitIn(t, unborn, "init", "-q", "-b", "main")
	if base, err := openRepo(t, unborn).Base(ctx); err != nil || base.SHA != EmptyTree {
		t.Fatalf("Base on an unborn HEAD = %+v, %v; want the empty tree", base, err)
	}
	if _, err := openFailing(t, dir, "symbolic-ref", "refs/remotes/origin/HEAD").DefaultBranch(ctx); err == nil {
		t.Fatal("DefaultBranch on a failing symbolic-ref answered")
	}
}

func TestDefaultBranch(t *testing.T) {
	dir := newRepo(t)
	ctx := context.Background()
	if got, err := openRepo(t, dir).DefaultBranch(ctx); err != nil || got != "main" {
		t.Fatalf("DefaultBranch = %q, %v; want main", got, err)
	}
	head := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	gitIn(t, dir, "update-ref", "refs/remotes/origin/trunk", head)
	gitIn(t, dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
	if got, err := openRepo(t, dir).DefaultBranch(ctx); err != nil || got != "trunk" {
		t.Fatalf("DefaultBranch with origin/HEAD = %q, %v; want trunk", got, err)
	}
	other := newRepo(t)
	gitIn(t, other, "branch", "-m", "main", "develop")
	if got, err := openRepo(t, other).DefaultBranch(ctx); err != nil || got != "" {
		t.Fatalf("DefaultBranch without main/master = %q, %v; want empty", got, err)
	}
}

// A branch both local and on origin at different commits: Branch reads the
// local one (the owner's own work), BranchBase measures against origin's
// (what the branch merges into).
func TestBranchAndBase_LocalVersusOriginPrecedence(t *testing.T) {
	dir := newRepo(t)
	ctx := context.Background()
	gitIn(t, dir, "checkout", "-q", "-b", "feature")
	writeFile(t, dir, "f.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "f")
	originFeature := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	writeFile(t, dir, "g.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "g")
	localFeature := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	gitIn(t, dir, "update-ref", "refs/remotes/origin/feature", originFeature)
	gitIn(t, dir, "checkout", "-q", "-b", "task")
	writeFile(t, dir, "t.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "t")
	gitIn(t, dir, "update-ref", "refs/remotes/origin/task", originFeature)
	gitIn(t, dir, "checkout", "-q", "main")
	r := openRepo(t, dir)

	tip, ok, err := r.Branch(ctx, "task")
	if err != nil || !ok || tip.Ref != "refs/heads/task" {
		t.Fatalf("Branch = %+v, %v, %v; want the local branch", tip, ok, err)
	}
	if tip.Commit == originFeature {
		t.Fatal("Branch read origin's commit over the local one")
	}
	base, err := r.BranchBase(ctx, tip, "feature")
	if err != nil || base.SHA != originFeature || base.Label != "origin/feature" {
		t.Fatalf("BranchBase = %+v, %v; want origin/feature at %s (local is %s)", base, err, originFeature, localFeature)
	}
}

// A branch tip with no history in common with any base branch reads against
// the empty tree with a label the Desktop explains; a repository with no
// base branch at all keeps the empty label.
func TestBranchBase_NoCommonBase(t *testing.T) {
	dir := newRepo(t)
	ctx := context.Background()
	gitIn(t, dir, "checkout", "-q", "--orphan", "island")
	writeFile(t, dir, "i.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "i")
	gitIn(t, dir, "checkout", "-q", "main")
	r := openRepo(t, dir)
	tip, ok, err := r.Branch(ctx, "island")
	if err != nil || !ok {
		t.Fatal(ok, err)
	}
	base, err := r.BranchBase(ctx, tip, "")
	if err != nil || base.SHA != EmptyTree || base.Label != NoCommonBase {
		t.Fatalf("BranchBase = %+v, %v; want the empty tree, %q", base, err, NoCommonBase)
	}
	gitIn(t, dir, "checkout", "-q", "island")
	gitIn(t, dir, "branch", "-D", "main")
	base, err = r.BranchBase(ctx, tip, "")
	if err != nil || base.SHA != EmptyTree || base.Label != "" {
		t.Fatalf("BranchBase without any base branch = %+v, %v; want the empty tree, no label", base, err)
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
