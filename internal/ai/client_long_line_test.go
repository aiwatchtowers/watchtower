package ai

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
	"watchtower/internal/providers"
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

		ctx := context.Background()
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

	ctx := context.Background()
	text, _, err := c.QuerySync(ctx, "system", "hello", "")
	require.NoError(t, err)
	assert.Equal(t, strings.Repeat("b", 2<<20), text)
}

// lowerMaxStreamLine lowers the one-shot reader's limit for one test.
func lowerMaxStreamLine(t *testing.T, limit int) {
	t.Helper()
	old := maxStreamLine
	maxStreamLine = limit
	t.Cleanup(func() { maxStreamLine = old })
}

// A tool result over the limit is skipped: its step still ends, failed with
// a reason, the answer after it arrives, and only the count reaches the log
// (FILES-01).
func TestClaudeQuery_SkippedToolResultClosesItsStep(t *testing.T) {
	lowerMaxStreamLine(t, 4<<10)
	canary := logcanary.Text("tool_result")
	sink := logcanary.Capture(t)
	big := canary + strings.Repeat("x", 8<<10)
	script := `printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__watchtower__get_target","input":{}}]}}\n'
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"` + big + `"}]}}\n'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}\n'
printf '{"type":"result","subtype":"success","result":"done","session_id":"s1"}\n'
`
	c := NewClient("test-model", "", "")
	c.claudeCmd = writeMockClaude(t, script)
	c.EmitToolEvents()

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")
	var text strings.Builder
	var last *ToolEvent
	for chunk := range textCh {
		text.WriteString(chunk.Text)
		if chunk.Tool != nil {
			last = chunk.Tool
		}
	}
	require.NoError(t, <-errCh)
	assert.Equal(t, "done", text.String())
	require.NotNil(t, last)
	assert.Equal(t, ToolEvent{ID: "t1", Name: "mcp__watchtower__get_target", Done: true,
		Result: "claude's report of this tool's result could not be read"}, *last)
	assert.Contains(t, sink.String(), "claude: skipped 1 stream-json line(s) over 4096 bytes")
	sink.AssertClean(t)
}

// A skipped line with no result event after it may have been the answer:
// the turn fails instead of ending as a blank "complete" one.
func TestClaudeQuery_SkippedResultFailsTheTurn(t *testing.T) {
	lowerMaxStreamLine(t, 4<<10)
	big := strings.Repeat("y", 8<<10)
	script := `printf '{"type":"result","subtype":"success","result":"` + big + `","session_id":"s1"}\n'
`
	c := NewClient("test-model", "", "")
	c.claudeCmd = writeMockClaude(t, script)

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")
	for range textCh {
	}
	err := <-errCh
	require.Error(t, err)
	var failure *providers.Failure
	require.ErrorAs(t, err, &failure)
	assert.Equal(t, providers.InvalidOutput, failure.Category)
	assert.Contains(t, err.Error(), "1 line(s) over 4096 bytes skipped")
}
