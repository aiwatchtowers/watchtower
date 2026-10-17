package ai

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

// buildArgsT is buildArgs for tests that inspect the argv: the 0600
// system-prompt file a call writes (the file Query/QuerySync remove after
// the child exits) is removed when the test ends. Read its path from the
// argv with flagValue(t, args, "--system-prompt-file").
func buildArgsT(t *testing.T, c *Client, systemPrompt, userMessage, outputFormat, sessionID string) ([]string, string, error) {
	t.Helper()
	args, stdin, promptFile, err := c.buildArgs(systemPrompt, userMessage, outputFormat, sessionID)
	if promptFile != "" {
		t.Cleanup(func() { _ = os.Remove(promptFile) })
	}
	return args, stdin, err
}
