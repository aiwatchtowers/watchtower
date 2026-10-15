package workbenchgit

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func made(t *testing.T, dir string) WorktreeResult {
	t.Helper()
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "r"})
	require.True(t, res.Created, "%+v", res)
	return res
}

// dropWorktree removes a worktree the way a cleanup would, for the test only.
func dropWorktree(t *testing.T, dir string, wt WorktreeResult) {
	t.Helper()
	gitIn(t, dir, "worktree", "remove", wt.Path)
}

func TestWorktreeEnsure_RecreatesFromBranch(t *testing.T) {
	dir := newRepo(t)
	wt := made(t, dir)
	commit(t, wt.Path, "work.txt", "done\n", "work")
	dropWorktree(t, dir, wt)
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, "done\n", readFile(t, wt.Path, "work.txt"))
	again := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	assert.False(t, again.Created, "an existing worktree is left alone")
	assert.Empty(t, again.Error)
}

func TestWorktreeEnsure_DeletedByHandIsReAdded(t *testing.T) {
	dir := newRepo(t)
	wt := made(t, dir)
	require.NoError(t, os.RemoveAll(wt.Path))
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, wt.Branch, gitIn(t, wt.Path, "branch", "--show-current"))
}

func TestWorktreeEnsure_CopiesIncludePathsAgain(t *testing.T) {
	dir := includeRepo(t)
	wt := made(t, dir)
	dropWorktree(t, dir, wt)
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	assert.ElementsMatch(t, []string{".env", "node_modules/"}, res.Included)
}

func TestWorktreeEnsure_BranchGone(t *testing.T) {
	dir := newRepo(t)
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), filepath.Join(dir, ".claude", "worktrees", "z"), "wt/z")
	assert.Equal(t, RefusedUnknownBranch, res.Refused)
	assert.NoDirExists(t, filepath.Join(dir, ".claude", "worktrees", "z"))
}

func TestWorktreeEnsure_RefusesPathsOutsideTheWorktreesDir(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "branch", "wt/q")
	for _, p := range []string{dir, filepath.Join(dir, "elsewhere"), filepath.Join(dir, ".claude", "worktrees")} {
		res := EnsureWorktree(context.Background(), options(dir, &recorder{}), p, "wt/q")
		assert.Equal(t, RefusedInvalidName, res.Refused, p)
	}
	assert.Equal(t, RefusedInvalidName, EnsureWorktree(context.Background(), options(dir, &recorder{}),
		filepath.Join(dir, ".claude", "worktrees", "q"), "main").Refused)
}

func TestProj18_PlacementNeverForcesOrDiscards(t *testing.T) {
	dir := includeRepo(t)
	rec := &recorder{}
	o := options(dir, rec)
	ctx := context.Background()
	a := CreateWorktree(ctx, o, WorktreeRequest{Slug: "a"})
	b := CreateWorktree(ctx, o, WorktreeRequest{Slug: "b"})
	writeFile(t, b.Path, "README.md", "x\n")
	require.NoError(t, os.RemoveAll(a.Path))
	EnsureWorktree(ctx, o, a.Path, a.Branch)
	EnsureWorktree(ctx, o, b.Path, b.Branch)

	forbidden := []string{"remove", "--force", "-f", "-D", "-d", "--hard", "reset", "clean", "checkout", "stash", "--discard-changes"}
	require.NotEmpty(t, rec.argv())
	for _, c := range rec.argv() {
		for _, arg := range c {
			assert.NotContains(t, forbidden, arg, "git %s", strings.Join(c, " "))
		}
	}
	assert.Equal(t, "x\n", readFile(t, b.Path, "README.md"), "an existing worktree's changes are untouched")
}
