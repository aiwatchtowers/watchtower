package ai

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// twoMiBToolResult prints a stream-json user event whose tool_result
// carries 2 MiB of text: a line over the old 1 MiB scanner limit.
const twoMiBToolResult = `printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"'
head -c 2097152 /dev/zero | tr '\0' 'a'
printf '"}]}}\n'
`

// L1: a tool result over 1 MiB no longer fails the one-shot turn ("reading
// claude output"): the line is read, and the answer after it arrives.
func TestClaudeQuery_TwoMiBToolResultDoesNotFailTheTurn(t *testing.T) {
	script := `printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__watchtower__get_target","input":{}}]}}\n'
` + twoMiBToolResult + `printf '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}\n'
printf '{"type":"result","subtype":"success","result":"done","session_id":"s1"}\n'
`
	for _, v2 := range []bool{false, true} {
		c := NewClient("test-model", "", "")
		c.claudeCmd = writeMockClaude(t, script)
		c.toolEvents = v2

		// The bound turns a regression (a reader stuck before Wait) into a
		// failure instead of a hang.
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		t.Cleanup(cancel)
		textCh, errCh, _ := c.Query(ctx, "system", "hello", "")
		var text strings.Builder
		for chunk := range textCh {
			text.WriteString(chunk.Text)
		}
		require.NoError(t, <-errCh, "v2=%v", v2)
		assert.Equal(t, "done", text.String(), "v2=%v", v2)
	}
}

// The same 2 MiB line through QuerySync (--output-format json): the whole
// output is read, so the result comes through.
func TestClaudeQuerySync_TwoMiBLine(t *testing.T) {
	script := `printf '{"type":"result","subtype":"success","result":"'
head -c 2097152 /dev/zero | tr '\0' 'b'
printf '","usage":{"input_tokens":1,"output_tokens":1}}\n'
`
	c := NewClient("test-model", "", "")
	c.claudeCmd = writeMockClaude(t, script)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	text, _, err := c.QuerySync(ctx, "system", "hello", "")
	require.NoError(t, err)
	assert.Equal(t, strings.Repeat("b", 2<<20), text)
}
