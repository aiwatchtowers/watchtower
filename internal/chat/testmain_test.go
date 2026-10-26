package chat

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/auditlog"
	"watchtower/internal/db"
)

// TestMain installs the migrated-schema template so db.OpenTestDB is fast.
func TestMain(m *testing.M) {
	// Read tests' audit lines stay out of the machine's unified log.
	auditlog.SetSinkForTest(func(string) {})
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
