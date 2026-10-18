package authoring_test

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain seeds every new database file the tests open from the migrated
// schema template. Without it each db.Open of a file under t.TempDir() runs
// the full goose migration suite — ~15–25 s per test under -race, which put
// this package near main's 25-minute race timeout (#684).
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
