package chat

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/codex"
)

// codexStub is a stand-in codex binary that reads its stdin and prints
// jsonl, as `codex exec --json` does.
func codexStub(t *testing.T, jsonl string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fake CLI")
	}
	path := filepath.Join(t.TempDir(), "codex")
	body := "#!/bin/sh\ncat > /dev/null\ncat <<'__EOF__'\n" + jsonl + "\n__EOF__\n"
	require.NoError(t, os.WriteFile(path, []byte(body), 0o755))
	return path
}

// turnEvents collects the session's events up to the turn's terminal one.
func (h *harness) turnEvents() []Event {
	h.t.Helper()
	deadline := time.After(10 * time.Second)
	var out []Event
	for {
		select {
		case e, ok := <-h.events:
			require.True(h.t, ok, "session ended before the turn did")
			out = append(out, e)
			if e.Type == EventTurnDone || e.Type == EventError {
				return out
			}
		case <-deadline:
			h.t.Fatalf("turn did not end within 10s")
		}
	}
}

// A codex chat turn goes from codex's real JSONL through codex.Client and the
// turn backend: every tool call is a visible tool_start/tool_end step with
// its result (CHAT-02), the preamble is a separate paragraph, and the turn's
// usage reaches the message.
func TestTurnBackend_CodexToolCallsBecomeSteps(t *testing.T) {
	jsonl := strings.Join([]string{
		`{"type":"thread.started","thread_id":"th1"}`,
		`{"type":"turn.started"}`,
		`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll check the board."}}`,
		`{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{"status":"open"},"result":null,"error":null,"status":"in_progress"}}`,
		`{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{"status":"open"},"result":{"content":[{"type":"text","text":"[]"}],"structured_content":null},"error":null,"status":"completed"}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"No open targets."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":800,"output_tokens":90}}`,
	}, "\n")
	d, conv := seedConversation(t)
	b := NewTurnBackend(codex.NewClient("gpt-x", "", codexStub(t, jsonl)), d, conv)
	h := startSession(t, b, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})

	evs := h.turnEvents()
	var types []string
	var text strings.Builder
	for _, e := range evs {
		types = append(types, e.Type)
		text.WriteString(e.Text)
	}
	assert.Equal(t, []string{EventTurnStart, EventTextDelta, EventToolStart, EventToolEnd, EventTextDelta, EventUsage, EventTurnDone}, types)
	assert.Equal(t, "I'll check the board.\n\nNo open targets.", text.String())

	start, end := evs[2], evs[3]
	assert.Equal(t, "list_targets", start.Name)
	assert.Equal(t, "item_1", start.ID)
	assert.JSONEq(t, `{"status":"open"}`, string(start.Args))
	assert.Equal(t, "item_1", end.ID)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
	assert.Equal(t, "[]", end.Summary)

	u := evs[5]
	assert.Equal(t, "gpt-x", u.Model)
	assert.Equal(t, 1200, u.TokensIn)
	assert.Equal(t, 90, u.TokensOut)
	assert.Equal(t, StatusComplete, evs[6].Status)
	require.NoError(t, h.finish())
}

// A codex run that exits cleanly without turn.completed is an error turn,
// never a blank or partial "complete" answer.
func TestTurnBackend_CodexExitWithoutTurnCompletedIsAnError(t *testing.T) {
	jsonl := `{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll check the board."}}`
	d, conv := seedConversation(t)
	h := startSession(t, NewTurnBackend(codex.NewClient("gpt-x", "", codexStub(t, jsonl)), d, conv), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	e := h.next(EventError)
	assert.Equal(t, "t2", e.TurnID)
	assert.Contains(t, e.Message, "without completing the turn")
	require.NoError(t, h.finish())
}
