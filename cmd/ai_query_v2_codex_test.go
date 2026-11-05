package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
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
	require.NoError(t, os.WriteFile(path, []byte("#!/bin/sh\ncat > /dev/null\ncat <<'__EOF__'\n"+jsonl+"\n__EOF__\n"), 0o755))
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
	c := codex.NewClient("gpt-x", "", v2CodexStub(t))
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
	assert.Equal(t, "Let me check.\n\nFound it.", text.String())
	assert.Equal(t, 50, evs[5].TokensIn)
	assert.Equal(t, 7, evs[5].TokensOut)
}

// The tool router hands the chat events to the leaf it builds.
func TestToolRouteProvider_ForwardsChatEvents(t *testing.T) {
	leaf := codex.NewClient("gpt-x", "", v2CodexStub(t))
	p := &toolRouteProvider{}
	enableChatEvents(p)
	require.NoError(t, p.configureLeaf(leaf))
	evs := v2Events(t, leaf)
	var tools int
	for _, e := range evs {
		if e.Type == chat.EventToolStart {
			tools++
		}
	}
	assert.Equal(t, 1, tools)
}
