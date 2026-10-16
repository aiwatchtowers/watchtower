package fsutil

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNoSymlinkComponents(t *testing.T) {
	// t.TempDir lives under /var/folders, and /var is a link on macOS.
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	plain := filepath.Join(root, "a", "b")
	require.NoError(t, os.MkdirAll(plain, 0o700))
	target := filepath.Join(root, "target")
	require.NoError(t, os.MkdirAll(filepath.Join(target, "b"), 0o700))
	require.NoError(t, os.Symlink(target, filepath.Join(root, "link")))

	ok, err := NoSymlinkComponents(plain)
	require.NoError(t, err)
	assert.True(t, ok, "a plain path")

	ok, err = NoSymlinkComponents(filepath.Join(root, "link"))
	require.NoError(t, err)
	assert.False(t, ok, "the path itself is a link")

	ok, err = NoSymlinkComponents(filepath.Join(root, "link", "b"))
	require.NoError(t, err)
	assert.False(t, ok, "an ancestor is a link")

	ok, err = NoSymlinkComponents(filepath.Join(root, "missing", "x"))
	assert.ErrorIs(t, err, os.ErrNotExist)
	assert.False(t, ok)

	_, err = NoSymlinkComponents("relative/path")
	assert.Error(t, err)

	ok, err = NoSymlinkComponents("/")
	require.NoError(t, err)
	assert.True(t, ok)
}
