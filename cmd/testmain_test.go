package cmd

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests and
// points HOME at an empty directory for the whole package.
//
// The cmd package makes heavy use of db.Open(":memory:") — without the
// template cache every call runs goose migrations (~1 s each under -race),
// which exceeds Go's 10-minute test timeout on slow CI runners.
//
// HOME isolation: config.Load resolves an empty active_workspace from
// ~/.local/share/watchtower when exactly one workspace holds a database.
// Two dozen tests point flagConfig at a nonexistent file and expect a
// "config required" error; against the developer's real HOME they would
// instead resolve the real workspace and run the command for real (an AI
// query, a Slack sync). Tests that need their own HOME still t.Setenv it.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	home, err := os.MkdirTemp("", "watchtower-cmd-tests-home-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	if err := os.Setenv("HOME", home); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	code := m.Run()
	_ = os.RemoveAll(home)
	os.Exit(code)
}
