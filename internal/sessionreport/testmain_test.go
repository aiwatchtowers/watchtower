package sessionreport

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/gittest"
)

// TestMain installs the db schema template cache, so each db.Open(":memory:")
// clones a migrated snapshot and each db.Open of a new file under t.TempDir()
// starts from it, instead of running every migration (~30 s per test under
// -race).
//
// It also keeps git's background maintenance out of the test repositories
// (see gittest.DisableBackgroundGit).
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
