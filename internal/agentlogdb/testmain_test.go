package agentlogdb

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests: the
// move tests open a fresh watchtower.db under t.TempDir(), and without the
// template each of those runs the full goose migration suite (~30 s under
// -race), which pushed this package past main's race timeout (#875).
// TestOpen_DoesNotTouchGlobalGoose opts its second watchtower.db out with
// db.LeaveTestFileUnseeded: that one must really migrate.
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
