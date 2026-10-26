package coach

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache: every test opens a fresh
// watchtower.db under t.TempDir(), and without the template each of those runs
// the full goose migration suite.
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
