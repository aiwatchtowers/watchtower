package ai

import (
	"context"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAIClient_StreamJSONInputArgs(t *testing.T) {
	newC := func() *Client {
		c := NewClient("m", "/tmp/x.db", "/bin/claude")
		c.SetWatchtowerTools([]string{"list_targets"})
		c.SetMaxTurns(12)
		return c
	}
	off := newC()
	offArgs := off.ArgsForTest("sys", "msg")
	off.SetStreamJSONHooks(StreamJSONHooks{ExtraAllowed: []string{"A"}, ExtraDisallowed: []string{"D"}})
	assert.Equal(t, offArgs, off.ArgsForTest("sys", "msg"), "hooks without the mode change nothing")
	off.SetStreamJSONInput(false)
	assert.Equal(t, offArgs, off.ArgsForTest("sys", "msg"))
	assert.Contains(t, offArgs, "--strict-mcp-config")

	on := newC()
	on.SetStreamJSONInput(true)
	on.SetStreamJSONHooks(StreamJSONHooks{ExtraAllowed: []string{"mcp__claude_ai_Slack__slack_read_channel"},
		ExtraDisallowed: []string{"mcp__claude_ai_Slack__slack_send_message"}})
	args, stdin, _ := on.buildArgs("sys", "msg", "stream-json")
	assert.Empty(t, stdin, "the message goes as a stream-json line, not raw stdin")
	assert.NotContains(t, args, "--strict-mcp-config", "the claude.ai connectors load")
	joined := strings.Join(args, " ")
	for _, want := range []string{"--input-format stream-json", "--output-format stream-json", "--verbose",
		"--permission-prompt-tool stdio", "--setting-sources project,local", "--max-turns 12", "--no-session-persistence"} {
		assert.Contains(t, joined, want)
	}
	allowed := args[slices.Index(args, "--allowedTools")+1]
	assert.Equal(t, "mcp__watchtower__list_targets,mcp__claude_ai_Slack__slack_read_channel", allowed)
	disallowed := args[slices.Index(args, "--disallowedTools")+1]
	assert.True(t, strings.HasSuffix(disallowed, ",mcp__claude_ai_Slack__slack_send_message"), disallowed)
}

func TestAIClient_StreamJSONRun(t *testing.T) {
	bin := writeMockClaude(t, `read -r msg
echo '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"mcp__claude_ai_Slack__slack_send_message","input":{}}}'
read -r reply
case "$reply" in *deny-sentinel*) R=denied;; *) R=missing;; esac
case "$msg" in *hello-sentinel*) M=msg;; *) M=nomsg;; esac
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__claude_ai_Slack__slack_read_channel","input":{}}]}}'
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"channel text"}]}}'
echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"$R $M\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}"
cat >/dev/null
`)
	c := NewClient("m", "", bin)
	c.SetStreamJSONInput(true)
	var mu sync.Mutex
	var ready, controls []string
	var results []string
	c.SetStreamJSONHooks(StreamJSONHooks{
		WaitReady: func(context.Context, <-chan string, func(string) error) error {
			ready = append(ready, "waited")
			return nil
		},
		OnControl: func(line string) string {
			mu.Lock()
			defer mu.Unlock()
			controls = append(controls, line)
			return `{"deny-sentinel":1}`
		},
		OnToolResult: func(name string, isError bool, text string) {
			results = append(results, name+"|"+text)
			assert.False(t, isError)
		},
	})
	text, usage, err := c.QuerySync(t.Context(), "sys", "hello-sentinel", "")
	require.NoError(t, err)
	assert.Equal(t, "denied msg", text, "the message line and the control answer reached the child")
	assert.Equal(t, []string{"waited"}, ready)
	require.Len(t, controls, 1)
	assert.Contains(t, controls[0], "can_use_tool")
	assert.Equal(t, []string{"mcp__claude_ai_Slack__slack_read_channel|channel text"}, results)
	require.NotNil(t, usage)
	assert.Equal(t, int64(7), usage.Input)
	assert.Equal(t, int64(3), usage.Output)
}

func TestAIClient_StreamJSONWaitErrorEndsRun(t *testing.T) {
	bin := writeMockClaude(t, "cat >/dev/null\n")
	c := NewClient("m", "", bin)
	c.SetStreamJSONInput(true)
	c.SetStreamJSONHooks(StreamJSONHooks{WaitReady: func(context.Context, <-chan string, func(string) error) error {
		return assert.AnError
	}})
	_, _, err := c.QuerySync(t.Context(), "sys", "msg", "")
	require.ErrorIs(t, err, assert.AnError)
}
