package chat

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestListen_SameExecutableOffDarwin: the off-macOS session check accepts a
// client running the session's own executable (through a symlink too) and
// refuses another program, a gone pid and pid 1, over a fake proc tree.
func TestListen_SameExecutableOffDarwin(t *testing.T) {
	dir := t.TempDir()
	own := filepath.Join(dir, "watchtower")
	other := filepath.Join(dir, "other")
	require.NoError(t, os.WriteFile(own, []byte("x"), 0o700))
	require.NoError(t, os.WriteFile(other, []byte("y"), 0o700))
	link := filepath.Join(dir, "wt-link")
	require.NoError(t, os.Symlink(own, link))
	proc := filepath.Join(dir, "proc")
	for pid, target := range map[int]string{100: own, 200: other} {
		require.NoError(t, os.MkdirAll(filepath.Join(proc, strconv.Itoa(pid)), 0o700))
		require.NoError(t, os.Symlink(target, filepath.Join(proc, strconv.Itoa(pid), "exe")))
	}
	assert.NoError(t, sameExecutable(proc, 100, own))
	assert.NoError(t, sameExecutable(proc, 100, link))
	assert.ErrorIs(t, sameExecutable(proc, 200, own), errOtherExecutable)
	assert.ErrorIs(t, sameExecutable(proc, 300, own), errOtherExecutable)
	assert.ErrorIs(t, sameExecutable(proc, 1, own), errOtherExecutable)
}
