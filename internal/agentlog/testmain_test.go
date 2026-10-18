package agentlog

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/gittest"
)

// TestMain keeps git's background maintenance out of the test repositories
// (see gittest.DisableBackgroundGit) and seeds every new database file the
// tests open from the migrated schema template: each one migrated from
// scratch otherwise (~15 s under -race, #684).
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
