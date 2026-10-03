package workbenchgit

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/gitbin"
)

// Tracked and untracked files are listed relative to the folder (a
// subdirectory of the repository here); ignored ones are not.
func TestListFiles_RealRepository(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, ".gitignore", "*.log\n")
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "sub", "deep"), 0o755))
	writeFile(t, dir, "sub/a.md", "tracked\n")
	gitIn(t, dir, "add", ".gitignore", "sub/a.md")
	writeFile(t, dir, "sub/deep/b.txt", "untracked\n")
	writeFile(t, dir, "sub/c.log", "ignored\n")

	rec := &recorder{}
	got, err := ListFiles(context.Background(), options(filepath.Join(dir, "sub"), rec))
	require.NoError(t, err)
	assert.Equal(t, []string{"a.md", "deep/b.txt"}, got)
	assert.Equal(t, [][]string{{"ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."}}, rec.argv())
}

func TestListFiles_NoGitRunsNothing(t *testing.T) {
	dir := newRepo(t) // skips without git
	rec := &recorder{}
	_, err := ListFiles(context.Background(), options(t.TempDir(), rec))
	require.ErrorIs(t, err, errNotRepository)

	o := options(dir, rec)
	o.Locate = func() (string, bool) { return "", false }
	_, err = ListFiles(context.Background(), o)
	require.ErrorIs(t, err, gitbin.ErrUnavailable)
	assert.Empty(t, rec.argv())
}
