package cmd

import (
	"bufio"
	"bytes"
	"context"
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
	"watchtower/internal/config"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providers/transport"
)

// v2CodexStub prints one codex chat turn: a preamble, an MCP call, the
// answer and turn.completed with usage.
func v2CodexStub(t *testing.T) string {
	t.Helper()
	jsonl := strings.Join([]string{
		`{"type":"turn.started"}`,
		`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Let me check."}}`,
		`{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"status":"in_progress"}}`,
		`{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"result":{"content":[{"type":"text","text":"[]"}]},"status":"completed"}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Found it."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":7}}`,
	}, "\n")
	path := filepath.Join(t.TempDir(), "codex")
	script := "#!/bin/sh\n" +
		`if [ "$1" = --version ]; then echo 'codex-cli 0.166.0'; exit; fi` + "\n" +
		"cat > /dev/null\ncat <<'__EOF__'\n" + jsonl + "\n__EOF__\n"
	require.NoError(t, os.WriteFile(path, []byte(script), 0o755))
	return path
}

func v2Events(t *testing.T, p ai.Provider) []chat.Event {
	t.Helper()
	textCh, errCh, sidCh := p.Query(context.Background(), "sys", "hi", "")
	var buf bytes.Buffer
	streamQueryV2(&buf, "t1", textCh, errCh, sidCh)
	var out []chat.Event
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var e chat.Event
		require.NoError(t, json.Unmarshal(sc.Bytes(), &e))
		out = append(out, e)
	}
	return out
}

// `ai query --events v2` on codex renders the turn like the chat session:
// the tool call as a step, the preamble as its own paragraph, the usage.
func TestAIQueryV2_CodexGetsChatEvents(t *testing.T) {
	c := buildQuerier(&config.Config{CodexPath: v2CodexStub(t), AI: config.AIConfig{Provider: "codex"}},
		transport.Options{Model: "gpt-x", ToolEvents: true})
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
	assert.Equal(t, "Let me check.\n\nFound it.", text.String())
	assert.Equal(t, 50, evs[5].TokensIn)
	assert.Equal(t, 7, evs[5].TokensOut)
}

// The tool router builds its leaf with the query's options: the chat events
// reach the leaf.
func TestToolRouteProvider_ForwardsChatEvents(t *testing.T) {
	cfg := &config.Config{CodexPath: v2CodexStub(t), AI: config.AIConfig{Provider: "codex"}}
	cfg.AI.Fallback.Enabled, cfg.AI.Fallback.Provider = true, "claude"
	client, cleanup, err := newQueryClient(cfg, "", transport.Options{ToolEvents: true})
	require.NoError(t, err)
	t.Cleanup(cleanup)
	p, ok := client.(*toolRouteProvider)
	require.True(t, ok, "%T", client)
	actual := *cfg
	actual.AI.Fallback.Enabled = false
	leaf, cleanupLeaf, err := p.build(&actual)
	require.NoError(t, err)
	t.Cleanup(cleanupLeaf)
	evs := v2Events(t, leaf)
	var tools int
	for _, e := range evs {
		if e.Type == chat.EventToolStart {
			tools++
		}
	}
	assert.Equal(t, 1, tools)
}

// `ai query --events v2` through the real CLI entry, on codex directly and
// through the tool router (fallback on): the turn's tool call reaches stdout
// as tool_start/tool_end and its usage as a usage event. Guards the wiring
// in runAIQuery (transport.Options.ToolEvents) and in the router's leaf build,
// which the tests above call by hand.
func TestAIQueryV2_CodexChatEventsThroughTheCLI(t *testing.T) {
	for name, fallback := range map[string]string{
		"direct": "",
		"routed": "  fallback: {enabled: true, provider: claude}\n",
	} {
		t.Run(name, func(t *testing.T) {
			policytest.Set(t, nil)
			t.Setenv("HOME", t.TempDir())
			t.Setenv("CODEX_HOME", t.TempDir())
			dir := t.TempDir()
			config := filepath.Join(dir, "config.yaml")
			require.NoError(t, os.WriteFile(config, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
codex_path: %q
ai:
  provider: codex
%s`, v2CodexStub(t), fallback), 0o600))
			p := startCLI(t, "ai", "query", "--config", config, "--db-path", filepath.Join(dir, "wt.db"),
				"--events", "v2", "--", "hi")
			_ = p.stdin.Close()
			var types []string
			var usage chat.Event
			routed := false
			for line := range p.lines {
				var e chat.Event
				require.NoError(t, json.Unmarshal([]byte(line), &e), line)
				types = append(types, e.Type)
				if e.Type == chat.EventUsage {
					usage = e
				}
				// Only the tool router announces its pick (a routing chunk).
				routed = routed || (e.Type == chat.EventSessionReady && e.RoutingMode != "")
			}
			require.NoError(t, p.wait(), p.stderr.String())
			assert.Equal(t, name == "routed", routed, "the turn went through the tool router: %v", types)
			assert.Contains(t, types, chat.EventToolStart)
			assert.Contains(t, types, chat.EventToolEnd)
			assert.Equal(t, 7, usage.TokensOut, "%v", types)
		})
	}
}
