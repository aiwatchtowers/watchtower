package sessionreport

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/gittest"
)

// TestMain installs the db schema template cache, so each db.Open(":memory:")
// clones a migrated snapshot instead of running every migration.
//
// It also keeps git's background maintenance out of the test repositories
// (see gittest.DisableBackgroundGit).
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
