package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

// TestRotatingFile_RotatesWhileOpen pins the half of the log fix that bounds
// growth *during* a daemon's life, not only at its next start: several
// under-cap writes that cross the cap cumulatively must rotate, and the write
// after the rotation must land in the live path.
//
// That last assertion is the load-bearing one. A writer that renames the file
// but keeps appending through its original descriptor produces a correct
// looking ".1" and a live path that never grows again — the exact failure the
// inherited-fd problem on daemon.log is made of.
func TestRotatingFile_RotatesWhileOpen(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "watchtower.log")

	const capBytes = 64
	chunk := func(c byte) string { return strings.Repeat(string(c), 19) + "\n" }
	first := chunk('a') + chunk('b') + chunk('c') + chunk('d')
	require.Less(t, len(chunk('a')), capBytes,
		"each chunk must be under the cap: the point is that they cross it cumulatively")
	require.Greater(t, len(first), capBytes, "the four chunks together must cross the cap")

	w, err := newRotatingFile(path, capBytes)
	require.NoError(t, err)
	defer func() { _ = w.Close() }()

	for _, c := range []byte{'a', 'b', 'c', 'd'} {
		n, err := w.Write([]byte(chunk(c)))
		require.NoError(t, err)
		require.Equal(t, len(chunk(c)), n)
	}

	rotated, err := os.ReadFile(path + ".1")
	require.NoError(t, err, "the pre-rotation bytes must be in .1")
	assert.Equal(t, first, string(rotated))

	live, err := os.ReadFile(path)
	require.NoError(t, err, "a fresh live file must exist after the rotation")
	assert.Empty(t, string(live), "the live file must hold only post-rotation bytes")

	// The only assertion that catches "renamed but kept the old inode".
	_, err = w.Write([]byte(chunk('e')))
	require.NoError(t, err)

	live, err = os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, chunk('e'), string(live), "writes after a rotation must land in the live path")

	rotated, err = os.ReadFile(path + ".1")
	require.NoError(t, err)
	assert.Equal(t, first, string(rotated), "the rotated generation must stop growing")
}

// TestRotatingFile_SeedsSizeFromExistingFile pins the byte counter being
// seeded from the file already on disk. A counter starting at zero would let
// a daemon that restarts onto a nearly-full log write a whole further cap's
// worth before its first rotation.
func TestRotatingFile_SeedsSizeFromExistingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "watchtower.log")
	existing := strings.Repeat("x", 100)
	require.NoError(t, os.WriteFile(path, []byte(existing), 0o600))

	w, err := newRotatingFile(path, 64)
	require.NoError(t, err)
	defer func() { _ = w.Close() }()

	_, err = w.Write([]byte("first line\n"))
	require.NoError(t, err)

	rotated, err := os.ReadFile(path + ".1")
	require.NoError(t, err, "one small write onto an over-cap file must rotate immediately")
	assert.Equal(t, existing+"first line\n", string(rotated))

	live, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Empty(t, string(live))
}

// TestRotatingFile_RotationFailureIsNotedOncePerCap pins the retry policy on
// a rotation that cannot happen — a read-only log directory, or something
// occupying the ".1" path. The write must still succeed (rotation never
// blocks a sync), the failure must be visible in the log, and the note must
// come once per cap crossed rather than once per line: an unbounded note per
// line would be the very log amplification this writer exists to stop, in the
// one situation where rotation is already failing.
func TestRotatingFile_RotationFailureIsNotedOncePerCap(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "watchtower.log")
	// A directory at the .1 path makes os.Rename fail (EISDIR/ENOTDIR), the
	// same trick TestRotateLogIfOversized uses for its rename-failure subtest.
	require.NoError(t, os.Mkdir(path+".1", 0o755))

	w, err := newRotatingFile(path, 64)
	require.NoError(t, err)
	defer func() { _ = w.Close() }()

	for i := 0; i < 8; i++ {
		n, err := w.Write([]byte(strings.Repeat("x", 19) + "\n"))
		require.NoError(t, err, "a failed rotation must never fail the write")
		require.Equal(t, 20, n)
	}

	b, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, 2, strings.Count(string(b), "continuing without rotation"),
		"8 writes x 20 bytes over a 64-byte cap = one note per cap crossed, not one per line")
	assert.Contains(t, string(b), strings.Repeat("x", 19),
		"the lines themselves must still reach the log")
}

// TestLogWriterFor pins the one-stream half: a detached child's stdout and
// stderr ARE daemon.log, so adding os.Stderr to the logger wrote every line
// to both files. Only --verbose adds stderr now.
func TestLogWriterFor(t *testing.T) {
	t.Run("detached alone does not add stderr", func(t *testing.T) {
		buf := &bytes.Buffer{}
		assert.Same(t, buf, logWriterFor(buf, false, true),
			"a detached child must get the bare log file: its stderr already is daemon.log")
	})

	t.Run("plain foreground run does not add stderr", func(t *testing.T) {
		buf := &bytes.Buffer{}
		assert.Same(t, buf, logWriterFor(buf, false, false))
	})

	t.Run("verbose adds stderr", func(t *testing.T) {
		buf := &bytes.Buffer{}
		w := logWriterFor(buf, true, false)
		assert.NotSame(t, buf, w, "--verbose must fan out to stderr as well as the file")
		_, err := w.Write([]byte("line\n"))
		require.NoError(t, err)
		assert.Equal(t, "line\n", buf.String(), "the file must still get every line")
	})

	t.Run("verbose and detached still fans out", func(t *testing.T) {
		buf := &bytes.Buffer{}
		assert.NotSame(t, buf, logWriterFor(buf, true, true),
			"--verbose --detach duplicating is the operator asking for it")
	})
}

// TestNewSyncLogWriter_WrapsSyncLogPath pins which file the daemon's logger
// rotates. The intuitive wrong fix wraps the file named "daemon": daemon.log
// reaches the child as an inherited descriptor from a parent that has since
// exited, so renaming its path never moves the child's writes.
func TestNewSyncLogWriter_WrapsSyncLogPath(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}

	w, err := newSyncLogWriter(cfg)
	require.NoError(t, err)
	defer func() { _ = w.Close() }()

	assert.Equal(t, syncLogFilePath(cfg), w.path, "the logger writes watchtower.log")
	assert.NotEqual(t, logFilePath(cfg), w.path, "daemon.log cannot be rotated by the child that inherited it")
	assert.Equal(t, int64(maxLogSize), w.maxSize, "production uses the shared cap")
}
