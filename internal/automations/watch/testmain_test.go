package watch

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache (see the automations
// package's TestMain).
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
