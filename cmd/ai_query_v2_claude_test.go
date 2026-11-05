package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/policy/policytest"
)

// v2ClaudeStub prints one claude stream-json turn: a preamble, an MCP call,
// the answer and the result with usage.
func v2ClaudeStub(t *testing.T) string {
	t.Helper()
	jsonl := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"s"}`,
		`{"type":"assistant","message":{"model":"claude-x","content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"tu1","name":"mcp__watchtower__list_targets","input":{}}]}}`,
		`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"[]"}]}}`,
		`{"type":"assistant","message":{"model":"claude-x","content":[{"type":"text","text":"Found it."}]}}`,
		`{"type":"result","subtype":"success","result":"Found it.","session_id":"s","usage":{"input_tokens":40,"cache_read_input_tokens":10,"output_tokens":7}}`,
	}, "\n")
	path := filepath.Join(t.TempDir(), "claude")
	script := "#!/bin/sh\ncat > /dev/null\ncat <<'__EOF__'\n" + jsonl + "\n__EOF__\n"
	require.NoError(t, os.WriteFile(path, []byte(script), 0o755))
	return path
}

// `ai query --events v2` on claude renders the turn like the chat session:
// the tool call as a step (its display name), the preamble kept as its own
// paragraph, the usage — the embedded chats' steps and tokens on claude.
func TestAIQueryV2_ClaudeGetsChatEvents(t *testing.T) {
	c := ai.NewClient("claude-x", "", v2ClaudeStub(t))
	enableChatEvents(c)
	evs := v2Events(t, c)
	var types []string
	var text strings.Builder
	for _, e := range evs {
		types = append(types, e.Type)
		text.WriteString(e.Text)
	}
	assert.Equal(t, []string{chat.EventTurnStart, chat.EventTextDelta, chat.EventToolStart, chat.EventToolEnd,
		chat.EventTextDelta, chat.EventUsage, chat.EventTurnDone}, types)
	assert.Equal(t, "list_targets", evs[2].Name)
	require.NotNil(t, evs[3].OK)
	assert.True(t, *evs[3].OK)
	assert.Equal(t, "Let me check.\n\nFound it.", text.String())
	assert.Equal(t, 50, evs[5].TokensIn)
	assert.Equal(t, 7, evs[5].TokensOut)
	assert.Equal(t, "claude-x", evs[5].Model)
}

// Through the real CLI entry: runAIQuery switches the claude client onto the
// chat events for `--events v2`.
func TestAIQueryV2_ClaudeChatEventsThroughTheCLI(t *testing.T) {
	policytest.Set(t, nil)
	t.Setenv("HOME", t.TempDir())
	dir := t.TempDir()
	config := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(config, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
claude_path: %q
ai:
  provider: claude
`, v2ClaudeStub(t)), 0o600))
	p := startCLI(t, "ai", "query", "--config", config, "--db-path", filepath.Join(dir, "wt.db"),
		"--events", "v2", "--", "hi")
	_ = p.stdin.Close()
	var types []string
	var usage chat.Event
	for line := range p.lines {
		var e chat.Event
		require.NoError(t, json.Unmarshal([]byte(line), &e), line)
		types = append(types, e.Type)
		if e.Type == chat.EventUsage {
			usage = e
		}
	}
	require.NoError(t, p.wait(), p.stderr.String())
	assert.Contains(t, types, chat.EventToolStart)
	assert.Contains(t, types, chat.EventToolEnd)
	assert.NotContains(t, types, "reset")
	assert.Equal(t, 7, usage.TokensOut, "%v", types)
}
