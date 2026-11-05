package codex

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/logredact"
)

// queryAll runs c.Query to its end and returns every chunk and the error.
func queryAll(t *testing.T, c *Client) ([]ai.StreamChunk, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	textCh, errCh, sidCh := c.Query(ctx, "sys", "user", "")
	var chunks []ai.StreamChunk
	for ch := range textCh {
		chunks = append(chunks, ch)
	}
	for range sidCh {
	}
	var err error
	for e := range errCh {
		if err == nil {
			err = e
		}
	}
	require.NoError(t, ctx.Err(), "the run must end by itself")
	return chunks, err
}

func textOf(chunks []ai.StreamChunk) string {
	var b strings.Builder
	for _, c := range chunks {
		b.WriteString(c.Text)
	}
	return b.String()
}

// A chat turn's JSONL as codex exec prints it: a preamble, a watchtower MCP
// call, a failing shell command, the answer and turn.completed with usage.
var chatTurnJSONL = strings.Join([]string{
	`{"type":"thread.started","thread_id":"th1"}`,
	`{"type":"turn.started"}`,
	`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll check the board."}}`,
	`{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{"status":"open"},"result":null,"error":null,"status":"in_progress"}}`,
	`{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{"status":"open"},"result":{"content":[{"type":"text","text":"[{\"id\":7}]"}],"structured_content":null},"error":null,"status":"completed"}}`,
	`{"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"cat missing.txt","aggregated_output":"","exit_code":null,"status":"in_progress"}}`,
	`{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"cat missing.txt","aggregated_output":"cat: missing.txt: No such file","exit_code":1,"status":"failed"}}`,
	`{"type":"item.started","item":{"id":"item_3","type":"mcp_tool_call","server":"docs","tool":"search","arguments":{},"result":null,"error":null,"status":"in_progress"}}`,
	`{"type":"item.completed","item":{"id":"item_3","type":"mcp_tool_call","server":"docs","tool":"search","arguments":{},"result":null,"error":{"message":"server down"},"status":"failed"}}`,
	`{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"Here are the open targets."}}`,
	`{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":800,"output_tokens":90}}`,
}, "\n")

func TestQuery_ToolEventsFromCodexItems(t *testing.T) {
	c := NewClient("gpt-x", "", fakeCodexScript(t, chatTurnJSONL, "", 0))
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)

	var tools []ai.ToolEvent
	var usage []ai.TurnUsage
	for _, ch := range chunks {
		if ch.Tool != nil {
			tools = append(tools, *ch.Tool)
		}
		if ch.Usage != nil {
			usage = append(usage, *ch.Usage)
		}
	}
	require.Len(t, tools, 6, "one start and one end per tool item, not per stage")

	assert.Equal(t, ai.ToolEvent{ID: "item_1", Name: "mcp__watchtower__list_targets", Args: json.RawMessage(`{"status":"open"}`)}, tools[0])
	assert.Equal(t, ai.ToolEvent{ID: "item_1", Name: "mcp__watchtower__list_targets", Done: true, OK: true, Result: `[{"id":7}]`}, tools[1])

	assert.False(t, tools[2].Done)
	assert.Equal(t, "shell", tools[2].Name)
	assert.JSONEq(t, `{"command":"cat missing.txt"}`, string(tools[2].Args))
	assert.Equal(t, ai.ToolEvent{ID: "item_2", Name: "shell", Done: true, OK: false, Result: "cat: missing.txt: No such file"}, tools[3])

	assert.Equal(t, ai.ToolEvent{ID: "item_3", Name: "mcp__docs__search", Done: true, OK: false, Result: "server down"}, tools[5])

	assert.Equal(t, "I'll check the board.\n\nHere are the open targets.", textOf(chunks),
		"distinct agent messages are separated (protocol v2 never wipes the preamble)")
	assert.Equal(t, []ai.TurnUsage{{Model: "gpt-x", InputTokens: 1200, OutputTokens: 90}}, usage)
}

// Without the v2 events (ai query v1, the REPL) nothing but text and
// boundaries is streamed, and the post-tool answer starts fresh after the
// reset — no separator in front of it.
func TestQuery_V1StreamKeepsResetContract(t *testing.T) {
	c := NewClient("gpt-x", "", fakeCodexScript(t, chatTurnJSONL, "", 0))
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	var visible strings.Builder
	for _, ch := range chunks {
		assert.Nil(t, ch.Tool)
		assert.Nil(t, ch.Usage)
		if ch.ToolBoundary {
			visible.Reset()
		}
		visible.WriteString(ch.Text)
	}
	assert.Equal(t, "Here are the open targets.", visible.String())
}

// Two agent messages with no tool between them are separated for every
// consumer.
func TestQuery_SeparatesMessagesWithoutTool(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"First."}}`,
		`{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Second."}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	chunks, err := queryAll(t, NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0)))
	require.NoError(t, err)
	assert.Equal(t, "First.\n\nSecond.", textOf(chunks))
}

// A clean exit is a success only after turn.completed.
func TestQuery_CleanExitWithoutTurnCompletedFails(t *testing.T) {
	for name, stdout := range map[string]string{
		"empty":         "",
		"preamble only": `{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll check the board."}}`,
		"garbage":       "not json",
	} {
		t.Run(name, func(t *testing.T) {
			_, err := queryAll(t, NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0)))
			require.ErrorIs(t, err, errNoTurnCompleted)
		})
	}
}

// longLineStub writes a codex stub that prints a command_execution item
// whose output is n bytes on one line, then the answer and turn.completed.
// It leads its own process group; the cleanup kills the group if it is
// still alive and waits until it is gone.
func longLineStub(t *testing.T, n int) string {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := filepath.Join(dir, "codex")
	body := `#!/bin/sh
echo $$ > '` + pidFile + `'
cat > /dev/null
echo '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"cat big","exit_code":null,"status":"in_progress","aggregated_output":""}}'
printf '%s' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"cat big","exit_code":0,"status":"completed","aggregated_output":"'
head -c ` + strconv.Itoa(n) + ` /dev/zero | tr '\000' 'a'
printf '%s\n' '"}}'
echo '{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"done"}}'
echo '{"type":"turn.completed"}'
`
	require.NoError(t, os.WriteFile(script, []byte(body), 0o755))
	t.Cleanup(func() {
		b, _ := os.ReadFile(pidFile)
		pgid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
		if pgid <= 0 || syscall.Kill(-pgid, 0) == syscall.ESRCH {
			return
		}
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		deadline := time.Now().Add(10 * time.Second)
		for syscall.Kill(-pgid, 0) != syscall.ESRCH {
			if time.Now().After(deadline) {
				t.Errorf("stub process group %d still alive", pgid)
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
	})
	return script
}

// A tool item over 1 MiB (a shell printing a big file) is decoded like any
// other line: its result reaches the chat and the answer follows.
func TestQuery_LineOverOneMiBIsRead(t *testing.T) {
	c := NewClient("gpt-x", "", longLineStub(t, 3<<20))
	c.SetProcessGroup(true)
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	var end *ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil && ch.Tool.Done {
			end = ch.Tool
		}
	}
	require.NotNil(t, end)
	assert.Len(t, end.Result, 3<<20)
	assert.Equal(t, "done", textOf(chunks))
}

// A line over the limit is read to its end and skipped: codex, still
// writing it into the pipe, is never left blocked, and the run ends with
// the answer that follows.
func TestQuery_LineOverLimitIsSkippedAndTheRunEnds(t *testing.T) {
	old := maxStreamLine
	maxStreamLine = 4 << 10
	t.Cleanup(func() { maxStreamLine = old })

	c := NewClient("gpt-x", "", longLineStub(t, 1<<20))
	c.SetProcessGroup(true)
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	assert.Equal(t, "done", textOf(chunks))

	// The skipped line was the tool's end: the step is closed as failed,
	// never left running.
	var tools []ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil {
			tools = append(tools, *ch.Tool)
		}
	}
	require.Len(t, tools, 2)
	assert.Equal(t, ai.ToolEvent{ID: "item_1", Name: "shell", Done: true, Result: "this tool's result was too large to show"}, tools[1])
}

// A tool codex never reports the end of is closed as failed when the
// stream ends.
func TestQuery_UnfinishedToolIsClosed(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"status":"in_progress"}}`,
		`{"type":"turn.failed","error":{"message":"stream disconnected"}}`,
	}, "\n")
	c := NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 1))
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.Error(t, err)
	var last *ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil {
			last = ch.Tool
		}
	}
	require.NotNil(t, last)
	assert.Equal(t, ai.ToolEvent{ID: "item_1", Name: "mcp__watchtower__list_targets", Done: true, Result: "codex stopped before reporting this tool's result"}, *last)
}

// A failed command or MCP call with no output still says why.
func TestToolEnd_FailureAlwaysHasAReason(t *testing.T) {
	one := 1
	s := &queryStream{}
	for want, item := range map[string]*CodexItem{
		"the command was declined":       {Type: "command_execution", Status: "declined"},
		"the command exited with code 1": {Type: "command_execution", Status: "failed", ExitCode: &one},
		"the command failed":             {Type: "command_execution", Status: "failed"},
		"the tool failed":                {Type: "mcp_tool_call", Status: "failed", ToolError: &CodexItemFailure{}},
	} {
		end := s.toolEnd(item)
		assert.False(t, end.OK, want)
		assert.Equal(t, want, end.Result)
	}
	// A failed MCP call with neither an error nor a result (codex prints
	// "error":null,"result":null) still says why.
	for name, item := range map[string]*CodexItem{
		"no error, no result":  {Type: "mcp_tool_call", Status: "failed"},
		"blank result content": {Type: "mcp_tool_call", Status: "failed", Result: &CodexToolResult{}},
	} {
		end := s.toolEnd(item)
		assert.False(t, end.OK, name)
		assert.Equal(t, "the tool failed", end.Result, name)
	}
}

// The watchtower server is mounted as watchtower-app when the owner's codex
// config has its own watchtower; its tools still read as watchtower's, so
// the chat shows them by name and extracts their Sources.
func TestQuery_WatchtowerToolsUnderAnotherKey(t *testing.T) {
	home := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(home, "config.toml"),
		[]byte("[mcp_servers.watchtower]\nurl = \"https://mcp.example.com/mcp\"\n"), 0o600))
	stdout := strings.Join([]string{
		`{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower-app","tool":"search_knowledge","arguments":{},"status":"in_progress"}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	c := NewClient("gpt-x", filepath.Join(t.TempDir(), "w.db"), fakeCodexScript(t, stdout, "", 0))
	c.SetChildEnv([]string{"CODEX_HOME=" + home})
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	var names []string
	for _, ch := range chunks {
		if ch.Tool != nil && !ch.Tool.Done {
			names = append(names, ch.Tool.Name)
		}
	}
	assert.Equal(t, []string{"mcp__watchtower__search_knowledge"}, names)
}

// A clean exit without turn.completed keeps what the run said about it, so
// the chat can classify it (here a rate limit).
func TestQuery_IncompleteRunKeepsItsReason(t *testing.T) {
	stdout := `{"type":"error","message":"429 Too Many Requests"}`
	_, err := queryAll(t, NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0)))
	require.ErrorIs(t, err, errNoTurnCompleted)
	assert.Contains(t, logredact.Full(err), "429 Too Many Requests")

	_, err = queryAll(t, NewClient("gpt-x", "", fakeCodexScript(t, "", "stream closed early", 0)))
	require.ErrorIs(t, err, errNoTurnCompleted)
	assert.Contains(t, logredact.Full(err), "stream closed early")
}
