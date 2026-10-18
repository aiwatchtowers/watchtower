package automations_test

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests, for
// in-memory and fresh file-backed databases alike. Without it, every
// db.OpenTestDB call and every db.Open of a new file under t.TempDir() runs
// the full goose migration suite — ~12–25 s per test under -race, which
// pushed this package past main's 25-minute race timeout (#684).
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
