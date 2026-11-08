package ai

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

// L12: claude exiting 0 without a result event is a typed invalid_output
// failure on the one-shot path, never a blank or partial success; the text
// streamed before the exit is still delivered, and claude's stderr rides
// along in the error (codex and the batch path refuse the same run).
func TestClaudeQuery_ExitZeroWithoutResultIsInvalidOutput(t *testing.T) {
	cases := []struct {
		name, script, wantText, wantErr string
	}{
		{name: "partial answer", script: `printf '{"type":"assistant","message":{"content":[{"type":"text","text":"First message."}]}}\n'
`, wantText: "First message.", wantErr: "claude output had no result event"},
		{name: "no output", script: `exit 0
`, wantErr: "claude output had no result event"},
		{name: "stderr", script: `echo 'mcp server failed to start' >&2
`, wantErr: "claude output had no result event (stderr: mcp server failed to start)"},
	}
	for _, tc := range cases {
		for _, v2 := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/v2=%v", tc.name, v2), func(t *testing.T) {
				c := NewClient("test-model", "", "")
				c.claudeCmd = writeMockClaude(t, tc.script)
				c.toolEvents = v2

				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				t.Cleanup(cancel)
				textCh, errCh, _ := c.Query(ctx, "system", "hello", "")
				var text strings.Builder
				for chunk := range textCh {
					text.WriteString(chunk.Text)
				}
				err := <-errCh
				require.Error(t, err)
				var failure *providers.Failure
				require.ErrorAs(t, err, &failure)
				assert.Equal(t, providers.InvalidOutput, failure.Category)
				assert.Equal(t, tc.wantErr, logredact.Full(err))
				assert.Equal(t, tc.wantText, text.String(), "the partial text is delivered")
			})
		}
	}
}

// L12 on QuerySync: a clean exit whose output holds no result object is a
// typed invalid_output failure, never a blank or raw-output success, and
// never echoes the output (it is model-derived text).
func TestClaudeQuerySync_ExitZeroWithoutResultIsInvalidOutput(t *testing.T) {
	cases := map[string]string{
		"empty output":             `exit 0`,
		"array without result":     `printf '[{"type":"system","subtype":"init"},{"type":"assistant","message":{"content":[{"type":"text","text":"half an answer"}]}}]'`,
		"object that is no result": `printf '{"type":"half an answer","subtype":"init"}'`,
		"plain text":               `printf 'half an answer'`,
	}
	for name, script := range cases {
		t.Run(name, func(t *testing.T) {
			c := NewClient("test-model", "", "")
			c.claudeCmd = writeMockClaude(t, script)
			text, usage, err := c.QuerySync(context.Background(), "system", "hello", "")
			require.Error(t, err)
			var failure *providers.Failure
			require.ErrorAs(t, err, &failure)
			assert.Equal(t, providers.InvalidOutput, failure.Category)
			assert.Empty(t, text)
			assert.Nil(t, usage)
			assert.NotContains(t, err.Error(), "half an answer", "the output is described, never echoed")
		})
	}
}

// A clean exit without a result whose stderr is one of the CLI's own auth or
// rate-limit diagnostics takes that category ("sign in", "wait"), on Query
// and QuerySync alike; stderr that names nothing stays invalid_output.
func TestClaudeNoResult_StderrDiagnosticWins(t *testing.T) {
	cases := []struct {
		stderr string
		want   providers.ErrorCategory
	}{
		{"Invalid API key · Please run /login", providers.Auth},
		{"API Error: 401 {\"type\":\"error\"}", providers.Auth},
		{"API Error: 429 rate limited", providers.RateLimit},
		{"something unrelated happened", providers.InvalidOutput},
	}
	for _, tc := range cases {
		script := `echo '` + tc.stderr + `' >&2
exit 0`
		t.Run("Query/"+tc.stderr, func(t *testing.T) {
			c := NewClient("test-model", "", "")
			c.claudeCmd = writeMockClaude(t, script)
			textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")
			for range textCh {
			}
			var failure *providers.Failure
			require.ErrorAs(t, <-errCh, &failure)
			assert.Equal(t, tc.want, failure.Category)
		})
		t.Run("QuerySync/"+tc.stderr, func(t *testing.T) {
			c := NewClient("test-model", "", "")
			c.claudeCmd = writeMockClaude(t, script)
			_, _, err := c.QuerySync(context.Background(), "system", "hello", "")
			var failure *providers.Failure
			require.ErrorAs(t, err, &failure)
			assert.Equal(t, tc.want, failure.Category)
			assert.Contains(t, logredact.Full(err), tc.stderr)
		})
	}
}
