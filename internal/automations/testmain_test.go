package automations_test

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests.
// Without it, every db.OpenTestDB call runs the full goose migration suite —
// ~12 s per test under -race, which pushed this package past main's
// 25-minute race timeout.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
