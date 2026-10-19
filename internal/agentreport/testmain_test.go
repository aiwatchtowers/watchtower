package agentreport

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests: every
// report test opens a fresh watchtower.db under t.TempDir(), and without the
// template each of those runs the full goose migration suite (~20 s under
// -race), which pushed this package past main's race timeout (#875).
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
