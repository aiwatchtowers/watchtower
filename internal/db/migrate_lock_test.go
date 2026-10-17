package db

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/fsutil"
)

// TestOpenWaitsForAnotherProcessesMigrations: while another process holds
// the migration lock, Open does not run goose; it proceeds once the lock is
// released.
func TestOpenWaitsForAnotherProcessesMigrations(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	unlock, err := fsutil.LockFile(context.Background(), dbPath+".migrate.lock")
	require.NoError(t, err)

	type result struct {
		d   *DB
		err error
	}
	done := make(chan result, 1)
	go func() {
		d, err := Open(dbPath)
		done <- result{d, err}
	}()

	select {
	case r := <-done:
		if r.d != nil {
			_ = r.d.Close()
		}
		unlock()
		t.Fatalf("Open returned (err=%v) while another process held the migration lock", r.err)
	case <-time.After(300 * time.Millisecond):
	}
	unlock()

	select {
	case r := <-done:
		require.NoError(t, r.err)
		require.NoError(t, r.d.Close())
	case <-time.After(30 * time.Second):
		t.Fatal("Open did not proceed after the migration lock was released")
	}
}

// TestConcurrentOpensMigrateFreshFileOnce: several openers of one
// unmigrated file (the CLI, MCP servers and the session host's children right
// after an update) all succeed; none re-applies a migration another one ran.
func TestConcurrentOpensMigrateFreshFileOnce(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	freshMigrationPaths.Store(dbPath, true)

	const openers = 3
	errs := make([]error, openers)
	var wg sync.WaitGroup
	for i := range openers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			d, err := Open(dbPath)
			if err == nil {
				err = d.Close()
			}
			errs[i] = err
		}()
	}
	wg.Wait()
	for i, err := range errs {
		require.NoError(t, err, "opener %d", i)
	}
	_, seeded := seededPaths.Load(dbPath)
	require.False(t, seeded, "the file was seeded from the template, so goose never migrated it")
}
