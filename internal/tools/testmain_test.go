package tools

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/auditlog"
	"watchtower/internal/db"
	"watchtower/internal/gittest"
)

// TestMain installs the db schema template cache before running tests, for
// in-memory and fresh file-backed databases alike. Without it, every
// db.Open(":memory:") call and every db.Open of a new file under t.TempDir()
// (newAutoFixture) runs the full goose migration suite — ~20 s per test under
// -race.
//
// It also turns off git's background maintenance in the repositories the
// review tests create (see gittest.DisableBackgroundGit), and keeps the
// read tests' audit lines out of the machine's unified log.
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	auditlog.SetSinkForTest(func(string) {})
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
