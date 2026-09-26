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
//
// GO_WANT_HELPER_PROCESS short-circuit: several tests (cmd/shutdown_test.go,
// cmd/sync_stop_test.go, cmd/ideas_test.go) re-exec the test binary into a
// specific helper test via the standard os/exec.Command(os.Args[0], ...)
// re-exec pattern. That helper still runs through THIS package's TestMain
// first — it inherits it, there is no way to opt out per-test — so without
// this short-circuit every helper process pays the full db.InitTestTemplate
// cost (goose migrations against an in-memory db, ~8s under -race) before
// it ever reaches its own test body and prints "ready", which blows through
// the 5s readiness deadlines those tests use. None of the fixture setup
// below (db template, isolated HOME) is relevant to a helper process — it
// doesn't touch the database or read config — so it must run before any of
// it, not just before the DB call specifically.
func TestMain(m *testing.M) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") == "1" {
		os.Exit(m.Run())
	}
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
