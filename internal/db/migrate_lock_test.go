package db

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/require"

	"watchtower/internal/fsutil"
)

// openOnePending opens dbPath (seeded from the migrated template), rolls the
// newest migration back and closes it, so the next Open has exactly one
// migration to apply — the state right after an update.
func openOnePending(t *testing.T, dbPath string) {
	t.Helper()
	d, err := Open(dbPath)
	require.NoError(t, err)
	require.NoError(t, goose.Down(d.DB, "migrations"))
	require.NoError(t, d.Close())
}

// holdMigrateLock takes dbPath's migration lock as another process would and
// returns its release.
func holdMigrateLock(t *testing.T, dbPath string) func() {
	t.Helper()
	unlock, err := fsutil.LockFile(context.Background(), dbPath+".migrate.lock")
	require.NoError(t, err)
	var once sync.Once
	release := func() { once.Do(unlock) }
	t.Cleanup(release)
	return release
}

// requireNoVersionAppliedTwice opens dbPath and checks every embedded
// migration is recorded exactly once.
func requireNoVersionAppliedTwice(t *testing.T, dbPath string) {
	t.Helper()
	d, err := Open(dbPath)
	require.NoError(t, err)
	defer d.Close()
	var dups int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM (SELECT version_id FROM goose_db_version
		WHERE is_applied = 1 GROUP BY version_id HAVING COUNT(*) > 1)`).Scan(&dups))
	require.Zero(t, dups, "a migration was recorded as applied more than once")
	require.True(t, d.schemaCurrent(), "some embedded migration is not applied")
}

// openConcurrently opens dbPath from n goroutines at once and returns each
// Open's error (nil after a clean close).
func openConcurrently(dbPath string, n int) []error {
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Go(func() {
			d, err := Open(dbPath)
			if err == nil {
				err = d.Close()
			}
			errs[i] = err
		})
	}
	wg.Wait()
	return errs
}

// TestOpenWaitsForAnotherProcessesMigrations: with a migration pending and
// another process holding the migration lock, Open does not run goose; it
// proceeds once the lock is released.
func TestOpenWaitsForAnotherProcessesMigrations(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	openOnePending(t, dbPath)
	release := holdMigrateLock(t, dbPath)

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
		t.Fatalf("Open returned (err=%v) while another process held the migration lock", r.err)
	case <-time.After(300 * time.Millisecond):
	}
	release()

	select {
	case r := <-done:
		require.NoError(t, r.err)
		require.NoError(t, r.d.Close())
	case <-time.After(30 * time.Second):
		t.Fatal("Open did not proceed after the migration lock was released")
	}
}

// TestOpenCurrentSchemaSkipsMigrationLock: a file with nothing pending opens
// at once even while another process holds the migration lock.
func TestOpenCurrentSchemaSkipsMigrationLock(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := Open(dbPath)
	require.NoError(t, err)
	require.NoError(t, d.Close())
	holdMigrateLock(t, dbPath)

	old := migrateLockWait
	migrateLockWait = 50 * time.Millisecond
	t.Cleanup(func() { migrateLockWait = old })

	d, err = Open(dbPath)
	require.NoError(t, err)
	require.NoError(t, d.Close())
}

// TestOpenMigrationLockTimeoutIsRetryable: an Open that gives up waiting for
// another process's migrations fails with ErrMigrationInProgress, a
// temporary condition — not ErrSchemaSetup.
func TestOpenMigrationLockTimeoutIsRetryable(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	openOnePending(t, dbPath)
	holdMigrateLock(t, dbPath)

	old := migrateLockWait
	migrateLockWait = 100 * time.Millisecond
	t.Cleanup(func() { migrateLockWait = old })

	d, err := Open(dbPath)
	if d != nil {
		_ = d.Close()
	}
	require.ErrorIs(t, err, ErrMigrationInProgress)
	require.False(t, errors.Is(err, ErrSchemaSetup), "a lock timeout is not a schema failure: %v", err)
}

// TestOpenMigrationLockFailureIsSchemaSetup: a lock file that cannot be
// opened (here a directory in its place) is a real failure, ErrSchemaSetup
// with the cause — never the retryable ErrMigrationInProgress.
func TestOpenMigrationLockFailureIsSchemaSetup(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	openOnePending(t, dbPath)
	require.NoError(t, os.Remove(dbPath+".migrate.lock")) // left by the seeding open
	require.NoError(t, os.Mkdir(dbPath+".migrate.lock", 0o700))

	d, err := Open(dbPath)
	if d != nil {
		_ = d.Close()
	}
	require.ErrorIs(t, err, ErrSchemaSetup)
	require.False(t, errors.Is(err, ErrMigrationInProgress), "a broken lock file is not a migration in progress: %v", err)
}

// TestConcurrentOpensApplyPendingMigrationOnce: right after an update, ten
// openers of a file with a pending migration (the CLI, MCP servers, the
// session host's children) all succeed, and the migration is applied once.
func TestConcurrentOpensApplyPendingMigrationOnce(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	openOnePending(t, dbPath)

	for i, err := range openConcurrently(dbPath, 10) {
		require.NoError(t, err, "opener %d", i)
	}
	requireNoVersionAppliedTwice(t, dbPath)
}

// TestConcurrentOpensMigrateFreshFileOnce: several first opens of a new file
// (WAL switch plus every migration) all succeed. A full migration from
// scratch is slow under the race detector, so it is skipped there; the
// pending-migration test above covers the lock under -race.
func TestConcurrentOpensMigrateFreshFileOnce(t *testing.T) {
	if raceSlowdown > 1 {
		t.Skip("full migration from scratch is too slow under -race")
	}
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	freshMigrationPaths.Store(dbPath, true)

	for i, err := range openConcurrently(dbPath, 3) {
		require.NoError(t, err, "opener %d", i)
	}
	_, seeded := seededPaths.Load(dbPath)
	require.False(t, seeded, "the file was seeded from the template, so goose never migrated it")
	requireNoVersionAppliedTwice(t, dbPath)
}
