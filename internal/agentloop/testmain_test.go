package agentloop

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/auditlog"
	"watchtower/internal/db"
	"watchtower/internal/llmusage"
)

// TestMain seeds each new database file the tests open under t.TempDir()
// from the migrated template, instead of running the full goose migration
// suite per Open (~20 s per test under -race).
func TestMain(m *testing.M) {
	// Read tests' audit lines stay out of the machine's unified log.
	auditlog.SetSinkForTest(func(string) {})
	llmusage.SetSink(discardSink{}) // agentloop_llmusage_test.go
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
