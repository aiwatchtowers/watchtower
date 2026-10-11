package db

import (
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

	rw, err := OpenExistingRW(path, 100*time.Millisecond)
	require.NoError(t, err)
	defer rw.Close()
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
	p, err := rw.GetWorkbench(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", p.Name)
}
