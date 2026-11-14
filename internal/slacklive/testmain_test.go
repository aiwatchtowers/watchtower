package slacklive

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/llmusage"
)

// TestMain installs the db schema template cache (every db.Open(":memory:")
// would otherwise run the whole migration suite) and a discarding usage
// sink, so the probes' ledger calls stay out of any spool and off stderr.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	llmusage.SetSink(discardSink{})
	os.Exit(m.Run())
}
