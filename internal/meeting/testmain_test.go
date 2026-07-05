package meeting

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests.
// Without it, every db.Open(":memory:") call runs the full goose migration
// suite which under -race exceeds Go's 10-minute test timeout on CI.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
