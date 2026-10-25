package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// TestDaemonStart_SweepsExtractSpool: the startup sweep removes the prompt
// temp leftovers and the extract spool files a killed process left, and
// keeps the fresh ones.
func TestDaemonStart_SweepsExtractSpool(t *testing.T) {
	d := newQuietDaemon(t)
	d.config.ActiveWorkspace = "test"
	t.Setenv("HOME", t.TempDir())
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	spool := filepath.Join(d.config.WorkspaceDir(), "tmp", "extract")
	require.NoError(t, os.MkdirAll(spool, 0o700))

	old := time.Now().Add(-11 * time.Minute)
	write := func(p string, at time.Time) string {
		require.NoError(t, os.WriteFile(p, []byte("x"), 0o600))
		require.NoError(t, os.Chtimes(p, at, at))
		return p
	}
	oldSpool := write(filepath.Join(spool, "att-old.pdf"), old)
	freshSpool := write(filepath.Join(spool, "att-new.pdf"), time.Now())
	oldPrompt := write(filepath.Join(tmp, "wt-chat-prompt-1.txt"), old)

	d.sweepStaleTemp()

	require.NoFileExists(t, oldSpool)
	require.NoFileExists(t, oldPrompt)
	require.FileExists(t, freshSpool)
}
