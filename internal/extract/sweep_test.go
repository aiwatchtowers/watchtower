package extract

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSweepStaleRemovesCrashLeftovers: a spooled file a killed process left
// behind (older than StaleTempAge) is removed; a file in use and anything
// that is not a spooled attachment are left alone (EXT-03).
func TestSweepStaleRemovesCrashLeftovers(t *testing.T) {
	x := &Extractor{TempDir: filepath.Join(t.TempDir(), "tmp", "extract")}
	require.NoError(t, os.MkdirAll(x.TempDir, 0o700))
	now := time.Now()
	write := func(name string, age time.Duration) string {
		p := filepath.Join(x.TempDir, name)
		require.NoError(t, os.WriteFile(p, []byte("x"), 0o600))
		require.NoError(t, os.Chtimes(p, now.Add(-age), now.Add(-age)))
		return p
	}
	stale := write("att-111.pdf", StaleTempAge+time.Minute)
	fresh := write("att-222.pdf", StaleTempAge-time.Minute)
	foreign := write("notes.txt", time.Hour)
	require.NoError(t, os.Mkdir(filepath.Join(x.TempDir, "att-dir"), 0o700))

	n, err := x.SweepStale(now)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.NoFileExists(t, stale)
	assert.FileExists(t, fresh, "a file still in use is kept")
	assert.FileExists(t, foreign, "only spooled attachments are swept")
	assert.DirExists(t, filepath.Join(x.TempDir, "att-dir"))
}

func TestSweepStaleMissingDirIsNoOp(t *testing.T) {
	x := &Extractor{TempDir: filepath.Join(t.TempDir(), "never-created")}
	n, err := x.SweepStale(time.Now())
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Equal(t, 10*time.Minute, StaleTempAge)
}
