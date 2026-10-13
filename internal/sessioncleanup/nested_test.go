package sessioncleanup

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// TestProj16_WorktreeHoldingANestedWorktreeIsKept: `git worktree remove`
// (no --force) deletes a linked worktree nested under an ignored directory
// of the one it removes, uncommitted work included; such a worktree is
// kept.
func TestProj16_WorktreeHoldingANestedWorktreeIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	outer := f.worktree("wt-outer", "feat/outer")
	f.commit(outer, ".gitignore", ".claude/\n")
	gitIn(t, outer, "push", "-q", "origin", "feat/outer")
	nested := filepath.Join(outer, ".claude", "worktrees", "agent")
	gitIn(t, f.repo, "worktree", "add", "-q", "-b", "feat/nested", nested, "main")
	work := filepath.Join(nested, "unsaved.txt")
	writeFile(t, work, "uncommitted\n")
	f.record(outer, "feat/outer")

	res := f.apply(Request{}, nil, nil)
	it := wantResultItem(t, res, "worktree:"+outer, ActionKeep, ReasonContainsWorktree, false)
	if it.Detail != nested {
		t.Fatalf("detail = %q, want %s", it.Detail, nested)
	}
	wantResultItem(t, res, "branch:feat/outer", ActionKeep, ReasonCheckedOut, false)
	if !exists(work) || !f.listsWorktree(nested) || !exists(outer) {
		t.Fatal("the nested worktree or its uncommitted work is gone")
	}
}

func TestPlan_NestedRepositoryKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.worktree("wt", "feat/x")
	f.commit(root, ".gitignore", "vendor/\n")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	clone := filepath.Join(root, "vendor", "lib")
	gitIn(t, f.base, "init", "-q", clone)
	f.record(root, "feat/x")

	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonContainsWorktree)
	if it.Detail != clone {
		t.Fatalf("detail = %q, want %s", it.Detail, clone)
	}
}

func TestFindNestedRepository(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	writeFile(t, filepath.Join(root, ".git"), "gitdir: elsewhere\n")
	writeFile(t, filepath.Join(root, "a", "b", "file.txt"), "x\n")
	if got, err := findNestedRepository(context.Background(), root, time.Minute); err != nil || got != "" {
		t.Fatalf("own .git only: %q, %v", got, err)
	}
	if err := os.MkdirAll(filepath.Join(root, "a", "sub", ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, err := findNestedRepository(context.Background(), root, time.Minute); err != nil ||
		got != filepath.Join(root, "a", "sub") {
		t.Fatalf("nested .git dir: %q, %v", got, err)
	}
}

func TestFindNestedRepository_UnreadableDirectoryFailsClosed(t *testing.T) {
	t.Parallel()
	if os.Getuid() == 0 {
		t.Skip("root reads every directory")
	}
	root := t.TempDir()
	locked := filepath.Join(root, "locked")
	writeFile(t, filepath.Join(locked, "x.txt"), "x\n")
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	_, err := findNestedRepository(context.Background(), root, time.Minute)
	if err == nil || !strings.Contains(err.Error(), "nested") {
		t.Fatalf("err = %v, want the walk's failure", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	for i := range nestedClockEvery + 1 {
		writeFile(t, filepath.Join(root, "many", fmt.Sprintf("f%d", i)), "")
	}
	if err := os.Chmod(locked, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := findNestedRepository(ctx, root, time.Minute); err == nil {
		t.Fatal("a cancelled walk passed")
	}
}

// TestFindNestedRepository_SkipsRegenerableCaches: a package manager's
// checkout inside a dependency or build cache is not a nested repository;
// a repository anywhere else is.
func TestFindNestedRepository_SkipsRegenerableCaches(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	writeFile(t, filepath.Join(root, ".git"), "gitdir: elsewhere\n")
	for _, dir := range []string{
		filepath.Join("WatchtowerDesktop", ".build", "checkouts", "pkg", ".git"),
		filepath.Join("web", "node_modules", "x", "y", ".git"),
		filepath.Join("DerivedData", "a", ".git"),
		filepath.Join("ios", "Pods", "b", ".git"),
		filepath.Join(".swiftpm", "c", ".git"),
	} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, filepath.Join(root, "node_modules", "z", ".git"), "gitdir: elsewhere\n")
	if got, err := findNestedRepository(context.Background(), root, time.Minute); err != nil || got != "" {
		t.Fatalf("caches only: %q, %v", got, err)
	}
	stray := filepath.Join(root, "src", "vendor", "x")
	if err := os.MkdirAll(filepath.Join(stray, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, err := findNestedRepository(context.Background(), root, time.Minute); err != nil || got != stray {
		t.Fatalf("stray repository: %q, %v, want %s", got, err, stray)
	}
}

// ignoredCachesWork is a pushed worktree that ignores the caches and holds
// a Swift checkout and an npm package with their own `.git`.
func (f *fixture) ignoredCachesWork() string {
	f.t.Helper()
	root := f.worktree("wt", "feat/x")
	f.commit(root, ".gitignore", ".build/\nnode_modules/\n")
	gitIn(f.t, root, "push", "-q", "origin", "feat/x")
	if err := os.MkdirAll(filepath.Join(root, ".build", "checkouts", "pkg", ".git"), 0o755); err != nil {
		f.t.Fatal(err)
	}
	writeFile(f.t, filepath.Join(root, "node_modules", "x", ".git"), "gitdir: elsewhere\n")
	f.record(root, "feat/x")
	return root
}

func TestApply_CacheCheckoutsDoNotKeepTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.ignoredCachesWork()
	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	if exists(root) {
		t.Fatal("the worktree stays")
	}
}

// TestPlan_ListedWorktreeInsideACacheKeepsTheWorktree: the walk skips the
// caches, but a listed worktree in one is still found by the listing.
func TestPlan_ListedWorktreeInsideACacheKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	for i, cache := range []string{".build", "node_modules"} {
		t.Run(cache, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root := f.ignoredCachesWork()
			nested := filepath.Join(root, cache, "agent")
			gitIn(t, f.repo, "worktree", "add", "-q", "-b", fmt.Sprintf("feat/n%d", i), nested, "main")
			it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonContainsWorktree)
			if it.Detail != nested {
				t.Fatalf("detail = %q, want %s", it.Detail, nested)
			}
		})
	}
}

// TestApply_RepositoryNestedAfterThePlanIsCaughtBeforeTheRemove: the early
// re-checks reuse the evaluation's walk (the tree is walked at most twice
// per worktree); the one right before `git worktree remove` walks again
// and keeps the worktree.
func TestApply_RepositoryNestedAfterThePlanIsCaughtBeforeTheRemove(t *testing.T) {
	t.Parallel()
	for _, at := range []string{"first re-check", "lsregister"} {
		t.Run(at, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root := f.ignoredCachesWork()
			late := filepath.Join(root, "vendor", "late")
			f.commit(root, ".gitignore", ".build/\nnode_modules/\nvendor/\n")
			gitIn(t, root, "push", "-q", "origin", "feat/x")
			nest := func() {
				if err := os.MkdirAll(filepath.Join(late, ".git"), 0o755); err != nil {
					t.Error(err)
				}
			}
			log := &opLog{}
			ls := &fakeLS{log: log}
			procs := &dyingProcs{}
			if at == "lsregister" {
				ls.onUnregister = func(string) { nest() }
			} else {
				procs.onScan = func(n int) {
					if n == 2 {
						nest()
					}
				}
			}
			f.git = &loggingGit{log: log}
			res := f.apply(Request{}, nil, func(d *Deps) { d.LS, d.Procs = ls, procs })
			it := wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonContainsWorktree, false)
			if it.Detail != late || !exists(late) || slices.Contains(log.list(), "git worktree remove "+root) {
				t.Fatalf("detail %q, ops %v", it.Detail, log.list())
			}
			// The early re-check did not walk again: the bundles were
			// unregistered, and registered again once the worktree stayed.
			bundle := filepath.Join(root, "Build", "App.app")
			if !slices.Contains(log.list(), "lsregister -u "+bundle) || !slices.Contains(log.list(), "lsregister "+bundle) {
				t.Fatalf("ops %v", log.list())
			}
		})
	}
}
