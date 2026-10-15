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

func TestWorktreeCreate_CutsBranchFromHEAD(t *testing.T) {
	dir := newRepo(t)
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "229-worktrees"})
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, "wt/229-worktrees", res.Branch)
	assert.Equal(t, filepath.Join(dir, ".claude", "worktrees", "229-worktrees"), res.Path)
	assert.Equal(t, res.Path, res.Cwd)
	assert.Equal(t, gitIn(t, dir, "rev-parse", "HEAD"), res.Base)
	assert.Equal(t, "main", res.BaseBranch)
	assert.Equal(t, "wt/229-worktrees", gitIn(t, res.Path, "branch", "--show-current"))
	assert.Empty(t, gitIn(t, dir, "status", "--porcelain"), "the worktree never shows in the main folder")
}

func TestWorktreeCreate_SuffixesTakenNames(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "branch", "wt/x")
	o := options(dir, &recorder{})
	first := CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "x"})
	second := CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "x"})
	assert.Equal(t, "wt/x-2", first.Branch)
	assert.Equal(t, "wt/x-3", second.Branch)
}

func TestWorktreeCreate_ExcludeLineAddedOnce(t *testing.T) {
	dir := newRepo(t)
	o := options(dir, &recorder{})
	CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "a"})
	CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "b"})
	ex := readFile(t, filepath.Join(dir, ".git", "info"), "exclude")
	assert.Equal(t, 1, strings.Count(ex, "/.claude/worktrees/\n"))
}

func TestWorktreeCreate_SubfolderWorkbench(t *testing.T) {
	dir := newRepo(t)
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "app", "web"), 0o755))
	commit(t, filepath.Join(dir, "app", "web"), "index.js", "x\n", "web")
	res := CreateWorktree(context.Background(), options(filepath.Join(dir, "app", "web"), &recorder{}), WorktreeRequest{Slug: "s"})
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, filepath.Join(dir, ".claude", "worktrees", "s"), res.Path, "the worktree is the whole repository")
	assert.Equal(t, filepath.Join(res.Path, "app", "web"), res.Cwd)
}

func TestWorktreeCreate_BaseDirty(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "README.md", "edited\n")
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "d"})
	require.True(t, res.Created)
	assert.True(t, res.BaseDirty)
	assert.Equal(t, "hello\n", readFile(t, res.Path, "README.md"), "uncommitted changes stay in the main folder")
}

func TestWorktreeCreate_DetachedHEAD(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "switch", "-q", "--detach", "feature")
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "det"})
	require.True(t, res.Created, "%+v", res)
	assert.Empty(t, res.BaseBranch)
	assert.Equal(t, gitIn(t, dir, "rev-parse", "feature"), res.Base)
}

func TestWorktreeCreate_Refusals(t *testing.T) {
	plain := t.TempDir()
	assert.Equal(t, RefusedNotGit, CreateWorktree(context.Background(), Options{Folder: plain}, WorktreeRequest{Slug: "a"}).Refused)
	noGit := Options{Folder: newRepo(t), Locate: func() (string, bool) { return "", false }}
	assert.Equal(t, RefusedGitUnavailable, CreateWorktree(context.Background(), noGit, WorktreeRequest{Slug: "a"}).Refused)
	unborn, _ := filepath.EvalSymlinks(t.TempDir())
	gitIn(t, unborn, "init", "-q", "-b", "main")
	assert.Equal(t, RefusedUnborn, CreateWorktree(context.Background(), Options{Folder: unborn}, WorktreeRequest{Slug: "a"}).Refused)
	assert.Equal(t, RefusedInvalidName, CreateWorktree(context.Background(), Options{Folder: newRepo(t)}, WorktreeRequest{Slug: "../x"}).Refused)
}

func TestWorktreeCreate_SkipsANameASessionRowStillHolds(t *testing.T) {
	dir := newRepo(t)
	o := options(dir, &recorder{})
	res := CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "session-1", Taken: []string{"wt/session-1"}})
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, "wt/session-1-2", res.Branch, "a cleaned-up name whose row remains is never handed out again")
	assert.Equal(t, filepath.Join(dir, ".claude", "worktrees", "session-1-2"), res.Path)
}

func TestWorktreeCreate_SuffixKeepsTheSlugWithin40(t *testing.T) {
	dir := newRepo(t)
	o := options(dir, &recorder{})
	base := strings.Repeat("a", 38) + "-b" // 40, a dash at 39
	res := CreateWorktree(context.Background(), o, WorktreeRequest{Slug: base, Taken: []string{"wt/" + base}})
	require.True(t, res.Created, "%+v", res)
	slug := strings.TrimPrefix(res.Branch, "wt/")
	assert.LessOrEqual(t, len(slug), 40)
	assert.Equal(t, strings.Repeat("a", 38)+"-2", slug, "the base is trimmed, with no trailing dash, before the suffix")
}

func TestWorktreeCreate_SubfolderMissingFromHEADIsCreatedEmpty(t *testing.T) {
	dir := newRepo(t)
	sub := filepath.Join(dir, "app", "new")
	require.NoError(t, os.MkdirAll(sub, 0o755))
	res := CreateWorktree(context.Background(), options(sub, &recorder{}), WorktreeRequest{Slug: "s"})
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, filepath.Join(res.Path, "app", "new"), res.Cwd)
	assert.DirExists(t, res.Cwd)
	assert.Contains(t, res.Warning, "the workbench folder app/new is not in the commit; created it empty")
}
