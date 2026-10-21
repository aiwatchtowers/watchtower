package workbenchmethod

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain seeds each new database file the tests open under t.TempDir()
// from the migrated template, instead of running the full goose migration
// suite per Open (~20 s per test under -race).
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
