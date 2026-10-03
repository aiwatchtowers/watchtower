package db

import (
	"os"
	"path/filepath"
	"testing"
	"time"

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

// Another process holding the database exclusively: the read fails after
// the busy timeout, never Open's 5 s.
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
	assert.GreaterOrEqual(t, elapsed, 200*time.Millisecond, "it waited for the lock")
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
