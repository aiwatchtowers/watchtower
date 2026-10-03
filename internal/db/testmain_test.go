package db

import (
	"fmt"
	"os"
	"sync"
	"testing"
)

// TestMain initialises the schema template once, then runs all tests.
//
// Why: applying goose migrations to every in-memory DB (hundreds of tests ×
// ~1 s with the -race detector) exceeds Go's default 10-minute test timeout on
// slow CI runners. InitTestTemplate runs goose once, snapshots the migrated
// database, and installs openMemoryHook so every Open(":memory:") call in this
// binary returns a clone deserialized from that snapshot instead.
//
// It also installs seedNewFileHook: a file-backed Open of a path that does
// not exist yet starts from the same snapshot written to that file, so the
// tests about locking, file modes, DSNs and down/up cycles do not each pay a
// full migration (~15 s under -race on CI). A test about migrating a fresh
// file opens it with openMigratingFresh instead.
func TestMain(m *testing.M) {
	if err := InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	seedNewFileHook = seedFromTemplate
	os.Exit(m.Run())
}

// freshMigrationPaths holds the paths openMigratingFresh opens; Open leaves
// them unseeded so goose migrates them from scratch.
var freshMigrationPaths sync.Map

// seededPaths holds every path seedFromTemplate wrote the template to, so
// openMigratingFresh can prove its file was not one of them.
var seededPaths sync.Map

// seedFromTemplate writes the migrated template to the new file dbPath, at
// the 0644 SQLite itself creates a file with under the usual umask, so Open's
// permission tightening still has work to do.
func seedFromTemplate(dbPath string) error {
	if _, fresh := freshMigrationPaths.Load(dbPath); fresh {
		return nil
	}
	f, err := os.OpenFile(dbPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(templateSnapshot); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	seededPaths.Store(dbPath, true)
	return nil
}

// openMigratingFresh opens the new file dbPath through Open's real migration
// path, bypassing the template seed: goose applies every migration to an
// empty file.
func openMigratingFresh(t *testing.T, dbPath string) (*DB, error) {
	t.Helper()
	freshMigrationPaths.Store(dbPath, true)
	d, err := Open(dbPath)
	if _, seeded := seededPaths.Load(dbPath); seeded {
		if d != nil {
			_ = d.Close()
		}
		t.Fatalf("openMigratingFresh: %s was seeded from the template, so goose never migrated an empty file", dbPath)
	}
	return d, err
}

// openTestDB opens an isolated in-memory database for a test.
// When openMemoryHook is installed (i.e. InitTestTemplate was called) this
// returns a pre-migrated clone; otherwise it falls back to a full Open.
func openTestDB(t *testing.T) *DB {
	t.Helper()
	db, err := Open(":memory:")
	if err != nil {
		t.Fatalf("openTestDB: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}
