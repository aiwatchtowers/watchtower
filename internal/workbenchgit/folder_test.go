package workbenchgit

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"unicode"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// subfolderRepo is newRepo plus a committed app/ folder on main (feature
// has none) and a linked worktree "wt-b" made from main.
func subfolderRepo(t *testing.T) (repo, wtB string) {
	t.Helper()
	repo = newRepo(t)
	require.NoError(t, os.Mkdir(filepath.Join(repo, "app"), 0o755))
	commit(t, repo, "app/main.go", "package main\n", "app")
	return repo, addWorktree(t, repo, "wt-b", "main")
}

func resolve(t *testing.T, o Options, requested string) ResolvedFolder {
	t.Helper()
	got, err := ResolveFolder(context.Background(), o, requested)
	require.NoError(t, err)
	return got
}

// PROJ-10 (2026-10-12): a folder that is not one of the repository's
// worktrees is refused before any git runs in it — git runs only in the
// workbench folder, to list the worktrees.
func TestProj10_FolderOutsideTheWorktreesIsRefusedBeforeGit(t *testing.T) {
	repo := newRepo(t)
	outside, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	sibling := newRepo(t)
	missing := filepath.Join(outside, "gone")

	for _, tc := range []struct {
		requested string
		scope     FolderScope
	}{
		{outside, ScopeOutside},
		{sibling, ScopeOutside},
		{filepath.Join(sibling, "README.md"), ScopeOutside},
		{missing, ScopeMissing},
		{"relative/path", ScopeOutside},
	} {
		rec := &recorder{}
		got := resolve(t, options(repo, rec), tc.requested)
		assert.Equal(t, tc.scope, got.Scope, tc.requested)
		assert.True(t, got.OutsideTheRepository(), tc.requested)
		assert.Equal(t, repo, got.Root, "%s: the page falls back to the workbench folder", tc.requested)
		assert.Empty(t, got.WorktreeName, tc.requested)
		assert.Equal(t, tc.requested, got.Requested)
		for _, dir := range rec.ranIn() {
			assert.Equal(t, repo, dir, "%s: git ran only in the workbench folder", tc.requested)
		}
		if tc.scope == ScopeMissing || tc.requested == "relative/path" {
			assert.Empty(t, rec.argv(), "%s: no git at all", tc.requested)
		}
	}
}

func TestResolveFolderScopes(t *testing.T) {
	repo, wtB := subfolderRepo(t)
	wtC := addWorktree(t, repo, "wt-c", "feature") // no app/ on feature

	// A workbench at the repository's top level.
	top := Options{Folder: repo}
	for _, req := range []string{repo, filepath.Join(repo, "app")} {
		got := resolve(t, top, req)
		assert.Equal(t, ScopeMain, got.Scope, req)
		assert.Equal(t, repo, got.Root, req)
		assert.Equal(t, repo, got.MainTopLevel, req)
	}
	for _, req := range []string{wtB, filepath.Join(wtB, "app")} {
		got := resolve(t, top, req)
		assert.Equal(t, ScopeWorktree, got.Scope, req)
		assert.Equal(t, wtB, got.Root, req)
		assert.Equal(t, "wt-b", got.WorktreeName, req)
		assert.False(t, got.OutsideTheRepository())
	}

	// A workbench in a repository subfolder.
	app := filepath.Join(repo, "app")
	sub := Options{Folder: app}
	for _, req := range []string{"", app, repo} {
		got := resolve(t, sub, req)
		assert.Equal(t, ScopeMain, got.Scope, "%q", req)
		assert.Equal(t, app, got.Root, "%q: main runs git in the workbench folder", req)
	}
	got := resolve(t, sub, wtB)
	assert.Equal(t, ScopeWorktree, got.Scope)
	assert.Equal(t, filepath.Join(wtB, "app"), got.Root, "the subfolder maps into the worktree")
	got = resolve(t, sub, wtC)
	assert.Equal(t, ScopeWorktree, got.Scope)
	assert.Equal(t, wtC, got.Root, "no app/ in that worktree: its top level")
	assert.Equal(t, "wt-c", got.WorktreeName)
}

// A linked worktree inside the workbench folder (.claude/worktrees/…) is
// that worktree, not the main folder: the longest listed path wins.
func TestResolveFolderNestedWorktreeWins(t *testing.T) {
	repo := newRepo(t)
	nested := filepath.Join(repo, ".claude", "worktrees", "wt-n")
	gitIn(t, repo, "worktree", "add", "-q", "-b", "wt-n", nested, "main")

	got := resolve(t, Options{Folder: repo}, filepath.Join(nested, "README.md"))
	assert.Equal(t, ScopeWorktree, got.Scope)
	assert.Equal(t, nested, got.Root)
	assert.Equal(t, "wt-n", got.WorktreeName)
	assert.Equal(t, ScopeMain, resolve(t, Options{Folder: repo}, filepath.Join(repo, ".claude")).Scope)
}

// The workbench folder and the requested one may each reach the repository
// through a symlink (/tmp vs /private/tmp on macOS).
func TestResolveFolderSymlinkedPaths(t *testing.T) {
	repo, wtB := subfolderRepo(t)
	links := t.TempDir()
	repoLink, wtLink := filepath.Join(links, "repo"), filepath.Join(links, "wt")
	require.NoError(t, os.Symlink(repo, repoLink))
	require.NoError(t, os.Symlink(wtB, wtLink))

	for _, folder := range []string{repo, repoLink} {
		o := Options{Folder: folder}
		got := resolve(t, o, wtLink)
		assert.Equal(t, ScopeWorktree, got.Scope, folder)
		assert.Equal(t, wtB, got.Root, folder)
		got = resolve(t, o, filepath.Join(repoLink, "app"))
		assert.Equal(t, ScopeMain, got.Scope, folder)
		assert.Equal(t, folder, got.Root, "main keeps the workbench folder as stored")
	}
}

func TestResolveFolderNoGitRunsNothing(t *testing.T) {
	gitBin(t)
	plain, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	repo := newRepo(t)

	rec := &recorder{}
	got := resolve(t, options(plain, rec), plain)
	assert.Equal(t, ScopeOutside, got.Scope, "no repository")
	assert.Equal(t, plain, got.Root)

	got = resolve(t, options(repo, rec), "")
	assert.Equal(t, ScopeMain, got.Scope, "no folder asked: the workbench folder")
	assert.Equal(t, repo, got.Root)

	assert.Empty(t, rec.argv())
}

// Without git the folder is not refused as outside the worktrees: the scope
// is unresolved and the caller's git call says git is unavailable.
func TestResolveFolderGitUnavailableIsUnresolved(t *testing.T) {
	repo, wtB := subfolderRepo(t)
	rec := &recorder{}
	noGit := Options{Folder: repo, Run: rec.run, Locate: func() (string, bool) { return "", false }}
	got := resolve(t, noGit, wtB)
	assert.Equal(t, ScopeUnresolved, got.Scope)
	assert.False(t, got.OutsideTheRepository())
	assert.Equal(t, repo, got.Root)

	noGit.Folder = got.Root
	res := Switch(context.Background(), noGit, SwitchRequest{Branch: "feature"})
	assert.Equal(t, RefusedGitUnavailable, res.Refused)
	assert.False(t, ListBranches(context.Background(), noGit).GitAvailable)
	assert.Empty(t, rec.argv())
}

func TestResolveFolderGitFailureIsAnError(t *testing.T) {
	repo, wtB := subfolderRepo(t)
	rec := &recorder{fail: "worktree"}
	got, err := ResolveFolder(context.Background(), options(repo, rec), wtB)
	require.Error(t, err)
	assert.Equal(t, repo, got.Root)
	assert.Equal(t, ScopeUnresolved, got.Scope)
	assert.False(t, got.OutsideTheRepository(), "a failed listing is not a verdict")
}

// A workbench folder that no longer resolves gives no verdict either.
func TestResolveFolderUnresolvableWorkbenchIsAnError(t *testing.T) {
	repo, wtB := subfolderRepo(t)
	gone := filepath.Join(repo, "gone")
	got, err := ResolveFolder(context.Background(), Options{Folder: gone}, wtB)
	require.Error(t, err)
	assert.Equal(t, ScopeUnresolved, got.Scope)
	assert.Equal(t, gone, got.Root)
}

// A listing that leaves out the workbench's own worktree still places the
// workbench folder (and what is inside it) in main; anything else is
// outside.
func TestResolveFolderListingWithoutTheWorkbenchWorktree(t *testing.T) {
	repo, wtB := subfolderRepo(t)
	stale := func(context.Context, string, []byte, string, ...string) ([]byte, int, error) {
		return []byte("worktree " + filepath.Join(repo, "no-such-worktree") + "\x00\x00"), 0, nil
	}
	o := Options{Folder: repo, Run: stale}
	for _, req := range []string{repo, filepath.Join(repo, "app")} {
		got := resolve(t, o, req)
		assert.Equal(t, ScopeMain, got.Scope, req)
		assert.Equal(t, repo, got.Root, req)
	}
	assert.Equal(t, ScopeOutside, resolve(t, o, wtB).Scope)
}

// caseFlipped is path with the case of its letters swapped, or the test is
// skipped when the file system tells the two apart.
func caseFlipped(t *testing.T, path string) string {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("case-insensitive paths are a macOS rule")
	}
	flipped := strings.Map(func(r rune) rune {
		if unicode.IsUpper(r) {
			return unicode.ToLower(r)
		}
		return unicode.ToUpper(r)
	}, path)
	if _, err := os.Stat(flipped); err != nil {
		t.Skip("this volume is case-sensitive")
	}
	return flipped
}

// On macOS a folder spelt in another case than git lists it is that folder:
// neither refused as outside nor mistaken for another worktree.
func TestResolveFolderIgnoresCaseOnMacOS(t *testing.T) {
	repo, wtB := subfolderRepo(t)
	app := filepath.Join(repo, "app")

	got := resolve(t, Options{Folder: repo}, caseFlipped(t, filepath.Join(wtB, "app")))
	assert.Equal(t, ScopeWorktree, got.Scope)
	assert.Equal(t, wtB, got.Root)

	flippedRepo := Options{Folder: caseFlipped(t, repo)}
	got = resolve(t, flippedRepo, repo)
	assert.Equal(t, ScopeMain, got.Scope, "the workbench folder in another case is still main")
	assert.Equal(t, flippedRepo.Folder, got.Root)

	got = resolve(t, Options{Folder: caseFlipped(t, app)}, wtB)
	assert.Equal(t, ScopeWorktree, got.Scope)
	assert.True(t, samePath(filepath.Join(wtB, "app"), got.Root), "the subfolder maps across a case difference: %s", got.Root)
}

func TestResolveFolderSkipsPrunableAndBareEntries(t *testing.T) {
	out := []byte("worktree /r\x00bare\x00\x00" +
		"worktree /w1\x00HEAD abc\x00branch refs/heads/x\x00prunable gitdir file points to non-existent location\x00\x00")
	assert.Empty(t, worktreeTops(out))
}

func TestWithinIsAPathPrefix(t *testing.T) {
	assert.True(t, within("/a/b", "/a/b"))
	assert.True(t, within("/a/b/c", "/a/b"))
	assert.False(t, within("/a/bc", "/a/b"))
	assert.True(t, within("/a", "/"))
	assert.False(t, within("/a", "/a/b"))
}

// stubSameDirectory replaces the identity check for the test's duration.
func stubSameDirectory(t *testing.T, same func(a, b string) bool) {
	t.Helper()
	orig := sameDirectory
	sameDirectory = same
	t.Cleanup(func() { sameDirectory = orig })
}

// A case-only match counts only when both spellings are one directory: on a
// case-sensitive volume /x/WT beside the worktree /x/wt is another folder.
func TestWithinCaseOnlyMatchNeedsTheSameDirectory(t *testing.T) {
	var asked [][2]string
	stubSameDirectory(t, func(a, b string) bool {
		asked = append(asked, [2]string{a, b})
		return false
	})
	assert.False(t, within("/x/WT", "/x/wt"))
	assert.False(t, within("/x/WT/app", "/x/wt"))
	assert.False(t, within("/A/bc", "/a/b"))
	assert.Equal(t, [2]string{"/x/WT", "/x/wt"}, asked[0])
	assert.Equal(t, [2]string{"/x/WT/", "/x/wt/"}, asked[1], "the prefix is checked with its separator")
	assert.True(t, within("/x/wt/app", "/x/wt"), "an exact prefix needs no identity check")
	assert.Len(t, asked, 2, "a different-length or non-case-equal path needs no identity check")

	stubSameDirectory(t, func(string, string) bool { return true })
	assert.True(t, within("/A/b/c", "/a/B"))
	assert.False(t, within("/A/bc", "/a/b"), "still separator-safe")
}

// On a case-sensitive volume a folder that differs from a listed worktree
// only in case is outside, not that worktree.
func TestResolveFolderCaseOnlyMatchOfAnotherDirectoryIsOutside(t *testing.T) {
	repo, wtB := subfolderRepo(t)
	parent, base := filepath.Split(wtB)
	other := filepath.Join(parent, strings.ToUpper(base))
	if _, err := os.Stat(other); err != nil {
		require.NoError(t, os.Mkdir(other, 0o755)) // a case-sensitive temp volume
	}
	stubSameDirectory(t, func(string, string) bool { return false })
	got := resolve(t, Options{Folder: repo}, other)
	assert.Equal(t, ScopeOutside, got.Scope)
	assert.Equal(t, repo, got.Root)
	assert.Empty(t, got.WorktreeName)

	stubSameDirectory(t, func(string, string) bool { return true })
	got = resolve(t, Options{Folder: repo}, other)
	assert.Equal(t, ScopeWorktree, got.Scope, "the same directory in another case is that worktree")
	assert.Equal(t, base, got.WorktreeName)
}

// A requested folder that cannot be resolved for a reason other than not
// existing (a parent the user cannot read) gives no verdict: not outside,
// which a caller would map to the main folder.
func TestResolveFolderUnreadableRequestedIsUnresolved(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads any directory")
	}
	repo, wtB := subfolderRepo(t)
	locked := filepath.Join(wtB, "locked")
	inner := filepath.Join(locked, "inner")
	require.NoError(t, os.MkdirAll(inner, 0o755))
	require.NoError(t, os.Chmod(locked, 0o000))
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })

	rec := &recorder{}
	got, err := ResolveFolder(context.Background(), options(repo, rec), inner)
	require.Error(t, err)
	assert.Equal(t, ScopeUnresolved, got.Scope)
	assert.False(t, got.OutsideTheRepository(), "an unreadable folder is not a verdict")
	assert.Equal(t, repo, got.Root)
	assert.Empty(t, rec.argv(), "no git runs")
}
