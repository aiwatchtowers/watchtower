package cmd

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests.
//
// The cmd package makes heavy use of db.Open(":memory:") — without the
// template cache every call runs goose migrations (~1 s each under -race),
// which exceeds Go's 10-minute test timeout on slow CI runners.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
