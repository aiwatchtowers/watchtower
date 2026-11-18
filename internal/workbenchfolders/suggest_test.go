package workbenchfolders

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// RepoRoot walks up for .git without git: a linked worktree maps to its
// main repository (an absolute or a relative gitdir), a submodule stays
// itself, no .git is no root.
func TestRepoRootMapsWorktreesToTheirRepository(t *testing.T) {
	base, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	repo := filepath.Join(base, "repo")
	require.NoError(t, os.MkdirAll(filepath.Join(repo, ".git", "worktrees", "wt"), 0o755))

	root, ok := RepoRoot(filepath.Join(repo, "src", "a.go"))
	assert.True(t, ok)
	assert.Equal(t, repo, root)

	wt := filepath.Join(base, "wt")
	require.NoError(t, os.MkdirAll(wt, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: "+filepath.Join(repo, ".git", "worktrees", "wt")+"\n"), 0o600))
	root, ok = RepoRoot(filepath.Join(wt, "x"))
	assert.True(t, ok)
	assert.Equal(t, repo, root, "a linked worktree is its repository")

	rel := filepath.Join(base, "rel")
	require.NoError(t, os.MkdirAll(rel, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(rel, ".git"), []byte("gitdir: ../repo/.git/worktrees/wt"), 0o600))
	root, _ = RepoRoot(rel)
	assert.Equal(t, repo, root, "a relative gitdir")

	sub := filepath.Join(repo, "vendor", "lib")
	require.NoError(t, os.MkdirAll(sub, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(sub, ".git"), []byte("gitdir: ../../.git/modules/lib\n"), 0o600))
	root, _ = RepoRoot(filepath.Join(sub, "a.go"))
	assert.Equal(t, sub, root, "a submodule is a repository of its own")

	loose := filepath.Join(base, "loose")
	require.NoError(t, os.MkdirAll(loose, 0o755))
	if _, err := os.Lstat(filepath.Join(base, ".git")); err != nil {
		_, ok = RepoRoot(loose)
		assert.False(t, ok)
	}
}
