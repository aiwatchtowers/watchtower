package db

import (
	"fmt"
	"os"
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
// It calls InitTestFileTemplate, so a file-backed Open of a path that does
// not exist yet starts from the same snapshot written to that file, and the
// tests about locking, file modes, DSNs and down/up cycles do not each pay a
// full migration (~15 s under -race on CI). A test about migrating a fresh
// file opens it with openMigratingFresh instead.
func TestMain(m *testing.M) {
	if err := InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// openMigratingFresh opens the new file dbPath through Open's real migration
// path, bypassing the template seed: goose applies every migration to an
// empty file.
func openMigratingFresh(t *testing.T, dbPath string) (*DB, error) {
	t.Helper()
	LeaveTestFileUnseeded(dbPath)
	d, err := Open(dbPath)
	if TestFileSeeded(dbPath) {
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
