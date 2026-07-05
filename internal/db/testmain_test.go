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
// slow CI runners. InitTestTemplate runs goose once, caches the resulting DDL,
// and installs openMemoryHook so every Open(":memory:") call in this binary
// returns a pre-migrated clone in milliseconds instead.
func TestMain(m *testing.M) {
	if err := InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
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
