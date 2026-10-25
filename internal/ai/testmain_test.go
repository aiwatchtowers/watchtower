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

// buildArgsT is buildArgs for tests that inspect the argv only.
func buildArgsT(t *testing.T, c *Client, systemPrompt, userMessage, outputFormat string) ([]string, string, error) {
	t.Helper()
	args, stdin, _ := c.buildArgs(systemPrompt, userMessage, outputFormat)
	return args, stdin, nil
}

// payloadFor returns the content buildArgs hands the child for flag: the
// argv names it /dev/fd/N, the N-3rd payload.
func payloadFor(t *testing.T, args, payloads []string, flag string) string {
	t.Helper()
	path := flagValue(t, args, flag)
	var n int
	if _, err := fmt.Sscanf(path, "/dev/fd/%d", &n); err != nil || n < 3 || n-3 >= len(payloads) {
		t.Fatalf("%s = %q, want /dev/fd/N naming one of %d payloads", flag, path, len(payloads))
	}
	return payloads[n-3]
}
