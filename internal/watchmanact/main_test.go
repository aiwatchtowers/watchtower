package watchmanact

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/gittest"
)

// TestMain keeps git's background maintenance out of the test repositories
// (the hook tests create them) and installs the db schema template.
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
