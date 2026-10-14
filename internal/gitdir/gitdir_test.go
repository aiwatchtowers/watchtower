package gitdir

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The repositories here are laid out the way git writes them, because the
// package reads files only.

func tempDir(t *testing.T) string {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	return d
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(body), 0o644))
}

func TestFindWorkTree_WalksUpToTheNearestGitEntry(t *testing.T) {
	main := filepath.Join(tempDir(t), "acme")
	writeFile(t, filepath.Join(main, ".git", "HEAD"), "ref: refs/heads/main\n")
	admin := filepath.Join(main, ".git", "worktrees", "wt")
	wt := filepath.Join(main, "wt")
	writeFile(t, filepath.Join(wt, ".git"), "gitdir: "+admin+"\n")
	rel := filepath.Join(main, "rel")
	writeFile(t, filepath.Join(rel, ".git"), "gitdir: ../.git/worktrees/wt\n")
	outside := tempDir(t)

	for _, tc := range []struct {
		name, dir, root, gitDir string
		found                   bool
	}{
		{"main work tree", main, main, filepath.Join(main, ".git"), true},
		{"a missing dir inside it", filepath.Join(main, "gone", "deeper"), main, filepath.Join(main, ".git"), true},
		{"linked work tree", filepath.Join(wt, "sub"), wt, admin, true},
		{"relative gitdir", rel, rel, admin, true},
		{"outside any repository", outside, "", "", false},
	} {
		root, gitDir, found, err := FindWorkTree(tc.dir)
		require.NoError(t, err, tc.name)
		assert.Equal(t, tc.found, found, tc.name)
		assert.Equal(t, tc.root, root, tc.name)
		assert.Equal(t, tc.gitDir, gitDir, tc.name)
	}
}

// A broken inner .git stops the walk with an error; the enclosing
// repository is never taken instead (fail closed).
func TestFindWorkTree_ABrokenGitEntryFailsClosed(t *testing.T) {
	main := filepath.Join(tempDir(t), "acme")
	writeFile(t, filepath.Join(main, ".git", "HEAD"), "ref: refs/heads/main\n")
	for name, body := range map[string]string{
		"not a pointer": "not a pointer\n",
		"empty gitdir":  "gitdir:   \n",
		"too long":      "gitdir: " + strings.Repeat("x", pointerMaxBytes) + "\n",
	} {
		inner := filepath.Join(main, strings.ReplaceAll(name, " ", "-"))
		writeFile(t, filepath.Join(inner, ".git"), body)
		_, _, found, err := FindWorkTree(filepath.Join(inner, "sub"))
		require.Error(t, err, name)
		assert.False(t, found, name)
	}
}

func TestFindWorkTree_AnUnreadableDirStopsTheWalk(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	main := filepath.Join(tempDir(t), "acme")
	writeFile(t, filepath.Join(main, ".git", "HEAD"), "ref: refs/heads/main\n")
	locked := filepath.Join(main, "locked")
	require.NoError(t, os.MkdirAll(filepath.Join(locked, "sub"), 0o755))
	require.NoError(t, os.Chmod(locked, 0o000))
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })

	_, _, found, err := FindWorkTree(filepath.Join(locked, "sub"))
	require.Error(t, err, "a stat error other than not-exist is not skipped")
	assert.False(t, found)
}

func TestHeadBranch(t *testing.T) {
	for _, tc := range []struct{ name, head, branch string }{
		{"branch", "ref: refs/heads/feat/x\n", "feat/x"},
		{"detached", "0123456789abcdef0123456789abcdef01234567\n", ""},
		{"not a local branch", "ref: refs/remotes/origin/main\n", ""},
		{"reftable stub", "ref: refs/heads/.invalid\n", ""},
	} {
		gitDir := tempDir(t)
		writeFile(t, filepath.Join(gitDir, "HEAD"), tc.head)
		assert.Equal(t, tc.branch, HeadBranch(gitDir), tc.name)
	}
	assert.Empty(t, HeadBranch(tempDir(t)), "no HEAD file")
}
