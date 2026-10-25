package digest

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
	"watchtower/internal/logredact"
)

// TestFILES01_GeneratorStderr: the claude CLI's stderr and error envelope are
// kept whole in logredact.Full of the generator's error and reach the log only as a
// fingerprint.
func TestFILES01_GeneratorStderr(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	canary := logcanary.Text("stderr")
	sink := logcanary.Capture(t)
	ctx := context.Background()

	envelope := `{"type":"result","subtype":"error_during_execution","is_error":true,"result":"failed on \"` + canary + `\""}`
	for _, bin := range []string{fakeClaude(t, envelope, 1), fakeClaudeStderr(t, `error: "`+canary+`"`)} {
		_, _, _, err := NewClaudeGenerator("test-model", "test-model", bin).Generate(ctx, "sys", "msg", "")
		require.Contains(t, logredact.Full(err), canary)
		log.Printf("generate: %v", err)
	}

	require.Contains(t, sink.String(), "claude CLI failed")
	sink.AssertClean(t)
}

// fakeClaudeStderr is fakeClaude for a CLI that prints stderr on stderr and
// exits 1 with an empty stdout.
func fakeClaudeStderr(t *testing.T, stderr string) string {
	t.Helper()
	script := filepath.Join(t.TempDir(), "fake-claude")
	body := "#!/bin/sh\ncat >/dev/null\nprintf '%s' " + shellQuote(stderr) + " >&2\nexit 1\n"
	require.NoError(t, os.WriteFile(script, []byte(body), 0o755))
	return script
}

// The transport classifier reads the provider's own words through
// logredact.Full: a fingerprinted stderr must still classify.
func TestFILES01_TransportFailureSeesFullText(t *testing.T) {
	err := logredact.Errorf("claude CLI failed (exit 1): %s", logredact.Text("API Error: 529 overloaded_error"))
	require.NotContains(t, err.Error(), "overloaded")
	require.True(t, aiTransportFailure(err))
}
