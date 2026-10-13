package sessioncleanup

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
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
