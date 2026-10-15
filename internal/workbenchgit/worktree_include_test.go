package workbenchgit

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func includeRepo(t *testing.T) string {
	dir := newRepo(t)
	commit(t, dir, ".gitignore", ".env\nnode_modules/\nbuild/\nsecret.txt\n", "ignore")
	commit(t, dir, ".worktreeinclude", ".env\nnode_modules/\nREADME.md\n", "include")
	writeFile(t, dir, ".env", "KEY=1\n")
	writeFile(t, dir, "secret.txt", "not listed\n")
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "node_modules", "pkg"), 0o755))
	writeFile(t, filepath.Join(dir, "node_modules", "pkg"), "index.js", "module\n")
	return dir
}

func TestWorktreeInclude_CopiesListedIgnoredPathsOnly(t *testing.T) {
	dir := includeRepo(t)
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "inc"})
	require.True(t, res.Created, "%+v", res)
	assert.ElementsMatch(t, []string{".env", "node_modules/"}, res.Included)
	assert.Equal(t, "KEY=1\n", readFile(t, res.Path, ".env"))
	assert.Equal(t, "module\n", readFile(t, filepath.Join(res.Path, "node_modules", "pkg"), "index.js"))
	assert.NoFileExists(t, filepath.Join(res.Path, "secret.txt"), "ignored but not listed")
	assert.Empty(t, gitIn(t, res.Path, "status", "--porcelain"), "copied paths are ignored in the worktree too")
}

func TestWorktreeInclude_NoFileCopiesNothing(t *testing.T) {
	dir := newRepo(t)
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "none"})
	assert.Empty(t, res.Included)
	assert.Empty(t, res.IncludeWarnings)
}

func TestWorktreeInclude_SymlinkCopiedAsLink(t *testing.T) {
	dir := includeRepo(t)
	require.NoError(t, os.Remove(filepath.Join(dir, ".env")))
	require.NoError(t, os.Symlink("/etc/hosts", filepath.Join(dir, ".env")))
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "ln"})
	target, err := os.Readlink(filepath.Join(res.Path, ".env"))
	require.NoError(t, err)
	assert.Equal(t, "/etc/hosts", target)
}

func TestWorktreeInclude_FallbackCopyIsCapped(t *testing.T) {
	dir := includeRepo(t)
	saved, savedLimit := cloneFile, copyFallbackLimit
	t.Cleanup(func() { cloneFile, copyFallbackLimit = saved, savedLimit })
	cloneFile = func(string, string) error { return errCloneUnsupported }
	copyFallbackLimit = 8 // bytes: .env (6) fits, node_modules (7) does not
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "cap"})
	assert.True(t, res.Created, "an include warning never undoes the create")
	assert.Equal(t, []string{".env"}, res.Included)
	require.Len(t, res.IncludeWarnings, 1)
	assert.Contains(t, res.IncludeWarnings[0], "node_modules/")
	assert.NoDirExists(t, filepath.Join(res.Path, "node_modules"))
}
