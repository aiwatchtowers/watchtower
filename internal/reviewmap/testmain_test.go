package reviewmap

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/gittest"
)

// TestMain keeps git's background maintenance out of the test repositories
// (see gittest.DisableBackgroundGit) and installs the db schema template cache
// so in-memory databases skip the full migration suite.
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
