package ai

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"watchtower/internal/llmusage"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// collectChunks drains a Query's channels: its chunks and its error.
func collectChunks(t *testing.T, c *Client) []StreamChunk {
	t.Helper()
	textCh, errCh, sidCh := c.Query(context.Background(), "system", "hi", "")
	var chunks []StreamChunk
	for chunk := range textCh {
		chunks = append(chunks, chunk)
	}
	require.NoError(t, <-errCh)
	for range sidCh { //nolint:revive // drained so the goroutine's sends never block
	}
	return chunks
}

// With the chat events on (`ai query --events v2`), a claude tool call is a
// start/end pair, the turn's usage closes the stream, and text streamed
// before the call is kept — a later message starts after a blank line, never
// glued on and never wiped (CHAT-02's shape for the one-shot path).
func TestQuery_ChatEventsMakeToolStepsAndUsage(t *testing.T) {
	script := `
printf '{"type":"system","subtype":"init","session_id":"s"}\n'
printf '{"type":"assistant","message":{"model":"claude-test","content":[{"type":"text","text":"I need to check first."},{"type":"tool_use","id":"t1","name":"mcp__watchtower__list_jira_projects","input":{"limit":3}}]}}\n'
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"3 projects"}]}]}}\n'
printf '{"type":"assistant","message":{"model":"claude-test","content":[{"type":"tool_use","id":"t2","name":"ToolSearch","input":{}}]}}\n'
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"found"}]}}\n'
printf '{"type":"assistant","message":{"model":"claude-test","content":[{"type":"tool_use","id":"t3","name":"mcp__watchtower__get_person","input":{}}]}}\n'
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"no such person","is_error":true}]}}\n'
printf '{"type":"assistant","parent_tool_use_id":"t9","message":{"content":[{"type":"text","text":"subagent noise"}]}}\n'
printf '{"type":"assistant","message":{"model":"claude-test","content":[{"type":"text","text":"Here is the answer."}]}}\n'
printf '{"type":"result","subtype":"success","result":"Here is the answer.","session_id":"s","usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2,"output_tokens":7}}\n'
`
	c := NewClient("test-model", "", "")
	c.claudeCmd = writeMockClaude(t, script)
	c.EmitToolEvents()

	chunks := collectChunks(t, c)

	var text strings.Builder
	var tools []ToolEvent
	var usage *TurnUsage
	for _, ch := range chunks {
		assert.False(t, ch.ToolBoundary, "with the chat events on, no boundary chunk (v2 has no reset)")
		text.WriteString(ch.Text)
		if ch.Tool != nil {
			tools = append(tools, *ch.Tool)
		}
		if ch.Usage != nil {
			usage = ch.Usage
		}
	}
	assert.Equal(t, "I need to check first.\n\nHere is the answer.", text.String())
	require.Len(t, tools, 4, "t1 and t3 start and end; ToolSearch (Claude-internal) is hidden")
	assert.Equal(t, ToolEvent{ID: "t1", Name: "mcp__watchtower__list_jira_projects", Args: json.RawMessage(`{"limit":3}`)}, tools[0])
	assert.Equal(t, ToolEvent{ID: "t1", Name: "mcp__watchtower__list_jira_projects", Done: true, OK: true, Result: "3 projects"}, tools[1])
	assert.Equal(t, "t3", tools[2].ID)
	assert.Equal(t, ToolEvent{ID: "t3", Name: "mcp__watchtower__get_person", Done: true, OK: false, Result: "no such person"}, tools[3])
	require.NotNil(t, usage, "the result's usage closes the stream")
	assert.Equal(t, TurnUsage{Model: "claude-test", Tokens: llmusage.Tokens{Input: 10, CacheRead: 5, CacheWrite5m: 2, Output: 7}}, *usage)
	assert.Equal(t, 17, usage.InputTokens(), "tokens_in stays all input (CHAT-01)")
	assert.NotNil(t, chunks[len(chunks)-1].Usage, "usage is the last chunk")
}

// Without the chat events (`ai query` v1, every other caller) the stream is
// what it was: a boundary per tool call and no tool or usage chunks.
func TestQuery_NoChatEventsKeepsTheBoundaryStream(t *testing.T) {
	script := `
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__watchtower__x","input":{}}]}}\n'
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"r"}]}}\n'
printf '{"type":"result","subtype":"success","result":"","usage":{"input_tokens":1,"output_tokens":1}}\n'
`
	c := NewClient("test-model", "", "")
	c.claudeCmd = writeMockClaude(t, script)

	chunks := collectChunks(t, c)
	require.Len(t, chunks, 1)
	assert.True(t, chunks[0].ToolBoundary)
}

// Separate assistant messages are separated as the session translator
// separates them: a later message's text starts after a blank line, while
// two text blocks of one message (one message id) are glued.
func TestQuery_ChatEventsSeparateMessagesLikeTheTranslator(t *testing.T) {
	script := `
printf '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"One"}]}}\n'
printf '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":" more."}]}}\n'
printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Two."}]}}\n'
printf '{"type":"result","subtype":"success","result":"Two.","usage":{"input_tokens":1,"output_tokens":1}}\n'
`
	c := NewClient("test-model", "", "")
	c.claudeCmd = writeMockClaude(t, script)
	c.EmitToolEvents()

	var text strings.Builder
	for _, ch := range collectChunks(t, c) {
		text.WriteString(ch.Text)
	}
	assert.Equal(t, "One more.\n\nTwo.", text.String())
}
