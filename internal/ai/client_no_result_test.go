package ai

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/providers"
)

// L12: claude exiting 0 without a result event is a typed invalid_output
// failure on the one-shot path, never a blank or partial success; the text
// streamed before the exit is still delivered (codex and the batch path
// refuse the same run).
func TestClaudeQuery_ExitZeroWithoutResultIsInvalidOutput(t *testing.T) {
	cases := map[string]string{
		"partial answer": `printf '{"type":"assistant","message":{"content":[{"type":"text","text":"First message."}]}}\n'
`,
		"no output": `exit 0
`,
	}
	for name, script := range cases {
		for _, v2 := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/v2=%v", name, v2), func(t *testing.T) {
				c := NewClient("test-model", "", "")
				c.claudeCmd = writeMockClaude(t, script)
				c.toolEvents = v2

				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				t.Cleanup(cancel)
				textCh, errCh, _ := c.Query(ctx, "system", "hello", "")
				var text strings.Builder
				for chunk := range textCh {
					text.WriteString(chunk.Text)
				}
				err := <-errCh
				require.Error(t, err, "v2=%v", v2)
				var failure *providers.Failure
				require.ErrorAs(t, err, &failure)
				assert.Equal(t, providers.InvalidOutput, failure.Category)
				assert.Contains(t, err.Error(), "no result event")
				if name == "partial answer" {
					assert.Equal(t, "First message.", text.String(), "the partial text is delivered")
				}
			})
		}
	}
}
