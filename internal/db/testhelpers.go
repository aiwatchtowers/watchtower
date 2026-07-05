package db

import "testing"

// OpenTestDB opens an in-memory database for use by tests in other packages
// (e.g. internal/catchup). It registers cleanup on the test. The unexported
// openTestDB in this package's own tests does the same; this is the exported
// wrapper so cross-package tests don't duplicate setup.
func OpenTestDB(t *testing.T) *DB {
	t.Helper()
	d, err := Open(":memory:")
	if err != nil {
		t.Fatalf("opening in-memory test db: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return d
}
