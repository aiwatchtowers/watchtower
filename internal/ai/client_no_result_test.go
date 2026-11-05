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
