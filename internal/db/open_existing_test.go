package db

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The directory exists, so SQLite could create the file: only mode=rw
// keeps it from doing so.
func TestOpenExisting_NeverCreatesAFile(t *testing.T) {
	dir := t.TempDir()
	_, err := OpenExisting(filepath.Join(dir, "watchtower.db"), 100*time.Millisecond)
	require.Error(t, err)
	entries, readErr := os.ReadDir(dir)
	require.NoError(t, readErr)
	assert.Empty(t, entries, "no database file may be created")
}

func TestOpenExisting_ReadsAndRefusesWrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a ?dir", "watchtower.db")
	full, err := Open(path)
	require.NoError(t, err)
	id, err := full.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, full.Close())

	ro, err := OpenExisting(path, 100*time.Millisecond)
	require.NoError(t, err)
	defer ro.Close()
	p, err := ro.GetWorkbench(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", p.Name)
	_, err = ro.Exec(`DELETE FROM projects`)
	assert.Error(t, err, "a write must be refused")
}

// Another process holding the database exclusively: the read waits for the
// lock, then fails within the busy timeout, never Open's 5 s.
//
// The lower bound is a quarter of the timeout, not all of it: on Linux the
// driver sleeps between lock retries with a raw nanosleep syscall, which any
// signal reaching the sleeping thread cuts short with EINTR (never
// restarted), and SQLite's busy handler counts each sleep at its nominal
// length. So the total wait lands below busy_timeout now and then (measured
// under -race in a linux container: 35 of 400 runs under 200 ms, the
// shortest 144 ms). An immediate failure, with no wait at all, takes about
// 1 ms.
func TestOpenExisting_BusyTimeoutBoundsALockedDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	holder, err := Open(path)
	require.NoError(t, err)
	defer holder.Close()
	_, err = holder.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	lockExclusively(t, holder)

	start := time.Now()
	ro, err := OpenExisting(path, 200*time.Millisecond)
	if err == nil {
		defer ro.Close()
		_, err = ro.GetWorkbench(1)
	}
	require.Error(t, err, "the read must fail while the database is locked")
	assert.Contains(t, err.Error(), "SQLITE_BUSY")
	elapsed := time.Since(start)
	assert.GreaterOrEqual(t, elapsed, 50*time.Millisecond, "it waited for the lock")
	assert.Less(t, elapsed, 2*time.Second)
}

// lockExclusively makes d hold its database file exclusively until the test
// ends: exclusive locking mode, then a write left uncommitted.
func lockExclusively(t *testing.T, d *DB) {
	t.Helper()
	_, err := d.Exec(`PRAGMA locking_mode=EXCLUSIVE`)
	require.NoError(t, err)
	tx, err := d.Begin()
	require.NoError(t, err)
	_, err = tx.Exec(`UPDATE projects SET name = name`)
	require.NoError(t, err)
	t.Cleanup(func() { _ = tx.Rollback() })
}

// The guard's opener: no file is created, no migration runs over an old
// schema (HasColumns finds the gap), and a write goes through.
func TestOpenExistingRWNeverCreatesNeverMigrates(t *testing.T) {
	dir := t.TempDir()
	_, err := OpenExistingRW(filepath.Join(dir, "watchtower.db"), 100*time.Millisecond)
	require.Error(t, err)
	entries, readErr := os.ReadDir(dir)
	require.NoError(t, readErr)
	assert.Empty(t, entries, "no database file may be created")

	path := filepath.Join(t.TempDir(), "a ?dir", "watchtower.db")
	full, err := Open(path)
	require.NoError(t, err)
	has, err := full.HasColumns("terminal_sessions", "chat_question", "chat_question_at")
	require.NoError(t, err)
	assert.True(t, has, "the current schema has the chat question columns")
	require.NoError(t, goose.DownTo(full.DB, "migrations", 106))
	require.NoError(t, full.Close())
	require.NoError(t, os.Chmod(path, 0o644))

	rw, err := OpenExistingRW(path, 100*time.Millisecond)
	require.NoError(t, err)
	defer rw.Close()
	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm(), "the file modes are tightened as on Open")
	for _, tc := range []struct {
		table string
		cols  []string
	}{
		{"terminal_sessions", []string{"chat_question"}},
		{"owner_presence", nil},
		{"owner_presence", []string{"session_id"}},
	} {
		has, err := rw.HasColumns(tc.table, tc.cols...)
		require.NoError(t, err)
		assert.False(t, has, "%s %v on a 00106 schema", tc.table, tc.cols)
	}
	has, err = rw.HasColumns("terminal_sessions", "agent_state", "agent_background")
	require.NoError(t, err)
	assert.True(t, has, "columns the old schema does have")
	version, err := goose.GetDBVersion(rw.DB)
	require.NoError(t, err)
	assert.EqualValues(t, 106, version, "no migration ran")

	id, err := rw.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err, "a write must succeed")
	var fk int
	require.NoError(t, rw.QueryRow(`PRAGMA foreign_keys`).Scan(&fk))
	assert.Equal(t, 1, fk, "foreign keys are enforced")
	var sync int
	require.NoError(t, rw.QueryRow(`PRAGMA synchronous`).Scan(&sync))
	assert.Equal(t, 1, sync, "synchronous is NORMAL, as on Open")
	p, err := rw.GetWorkbench(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", p.Name)
}

// Another handle holding the database exclusively: a write through the rw
// opener fails busy within its own timeout, never Open's 5 s. The lower bound
// is a quarter of the timeout, as in the OpenExisting test above.
func TestOpenExistingRW_BusyTimeoutBoundsALockedDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	holder, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = holder.Close() })
	_, err = holder.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	lockExclusively(t, holder)

	start := time.Now()
	rw, err := OpenExistingRW(path, 100*time.Millisecond)
	if err == nil {
		t.Cleanup(func() { _ = rw.Close() })
		_, err = rw.Exec(`UPDATE projects SET name = 'other'`)
	}
	require.Error(t, err, "the write must fail while the database is locked")
	assert.Contains(t, err.Error(), "SQLITE_BUSY")
	elapsed := time.Since(start)
	assert.GreaterOrEqual(t, elapsed, 25*time.Millisecond, "it waited for the lock")
	assert.Less(t, elapsed, 2*time.Second)
}

// Another handle holding the write lock (RESERVED, readers still allowed):
// a write transaction on the rw handle begins IMMEDIATE, so BeginTx itself
// waits for the lock and fails busy; a DEFERRED begin would return at once.
func TestOpenExistingRW_WriteTransactionBeginsImmediate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	holder, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = holder.Close() })
	_, err = holder.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	held, err := holder.Begin()
	require.NoError(t, err)
	t.Cleanup(func() { _ = held.Rollback() })
	_, err = held.Exec(`UPDATE projects SET name = name`)
	require.NoError(t, err)

	rw, err := OpenExistingRW(path, 100*time.Millisecond)
	require.NoError(t, err)
	t.Cleanup(func() { _ = rw.Close() })
	var n int
	require.NoError(t, rw.QueryRow(`SELECT COUNT(*) FROM projects`).Scan(&n), "a read is not blocked")

	start := time.Now()
	tx, err := rw.BeginTx(context.Background(), nil)
	if err == nil {
		_ = tx.Rollback()
	}
	require.Error(t, err, "BEGIN IMMEDIATE must wait for the held write lock and fail")
	assert.Contains(t, err.Error(), "SQLITE_BUSY")
	elapsed := time.Since(start)
	assert.GreaterOrEqual(t, elapsed, 25*time.Millisecond, "it waited for the lock")
	assert.Less(t, elapsed, 2*time.Second)
}

// A migration that cannot apply is ErrSchemaSetup; a path that cannot be a
// database is not.
func TestOpenMarksSchemaSetupFailures(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	full, err := Open(path)
	require.NoError(t, err)
	require.NoError(t, goose.DownTo(full.DB, "migrations", 106))
	// The column 00107 adds is already there, so its ALTER fails.
	_, err = full.Exec(`ALTER TABLE owner_asks ADD COLUMN level TEXT`)
	require.NoError(t, err)
	require.NoError(t, full.Close())

	_, err = Open(path)
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrSchemaSetup)

	file := filepath.Join(t.TempDir(), "a-file")
	require.NoError(t, os.WriteFile(file, []byte("x"), 0o600))
	_, err = Open(filepath.Join(file, "watchtower.db")) // its directory is a file
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrSchemaSetup)
}
