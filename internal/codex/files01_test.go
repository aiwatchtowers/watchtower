package codex

import (
	"context"
	"log"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
	"watchtower/internal/logredact"
)

// TestFILES01_CodexStderrStaysOnTheError: codex's stderr and its turn
// message are kept whole in logredact.Full of the returned error and reach the log only as a
// fingerprint.
func TestFILES01_CodexStderrStaysOnTheError(t *testing.T) {
	canary := logcanary.Text("stderr")
	sink := logcanary.Capture(t)
	ctx := context.Background()

	for _, bin := range []string{
		fakeCodexRun(t, fixtureCase(t, "rate limit").JSONL, `warning: "`+canary+`"`, 1),
		fakeCodexRun(t, "", `error: "`+canary+`"`, 1),
		fakeCodexRun(t, `{"type":"turn.failed","error":{"message":"bad prompt \"`+canary+`\""}}`+"\n", "", 1),
	} {
		_, _, _, err := NewCodexGenerator("gpt-5.6-sol", "gpt-5.6-sol", bin).Generate(ctx, "sys", "msg", "")
		require.Contains(t, logredact.Full(err), canary)
		log.Printf("codex: %v", err)
	}

	require.Contains(t, sink.String(), "codex")
	sink.AssertClean(t)
}
