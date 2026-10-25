package ai

import (
	"context"
	"log"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
	"watchtower/internal/logredact"
)

// TestFILES01_ClaudeStderrStaysOnTheError: the CLI's stderr and its error
// envelope are kept whole in logredact.Full of the returned error and reach the log only as a
// fingerprint.
func TestFILES01_ClaudeStderrStaysOnTheError(t *testing.T) {
	canary := logcanary.Text("stderr")
	sink := logcanary.Capture(t)
	ctx := context.Background()

	stderr := writeMockClaude(t, `cat >/dev/null; printf 'error: prompt "`+canary+`" rejected\n' >&2; exit 1`)
	c := NewClient("test-model", "", "")
	c.claudeCmd = stderr
	_, _, err := c.QuerySync(ctx, "sys", "msg", "")
	require.Contains(t, logredact.Full(err), canary)
	log.Printf("query sync: %v", err)

	textCh, errCh, _ := c.Query(ctx, "sys", "msg", "")
	for range textCh {
	}
	err = <-errCh
	require.Contains(t, logredact.Full(err), canary)
	log.Printf("query: %v", err)

	envelope := writeMockClaude(t, `cat >/dev/null; printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"failed on \"`+canary+`\""}'; exit 1`)
	c.claudeCmd = envelope
	_, _, err = c.QuerySync(ctx, "sys", "msg", "")
	require.Contains(t, logredact.Full(err), canary)
	log.Printf("envelope: %v", err)

	require.Contains(t, sink.String(), "claude CLI failed")
	sink.AssertClean(t)
}
