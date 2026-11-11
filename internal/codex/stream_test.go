package codex

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/llmusage"
	"watchtower/internal/logcanary"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

// queryAll runs c.Query to its end and returns every chunk and the error.
func queryAll(t *testing.T, c *Client) ([]ai.StreamChunk, error) {
	t.Helper()
	textCh, errCh, sidCh := c.Query(context.Background(), "sys", "user", "")
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
	assert.Equal(t, []ai.TurnUsage{{Model: "gpt-x", Tokens: llmusage.Tokens{Input: 400, CacheRead: 800, Output: 90}}}, usage)
	assert.Equal(t, 1200, usage[0].InputTokens(), "tokens_in stays all input (CHAT-01)")
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
	t.Cleanup(func() { reapGroup(readPID(pidFile)) })
	return script
}

// A tool item over 1 MiB (a shell printing a big file) is decoded like any
// other line: its result reaches the chat and the answer follows.
func TestQuery_LineOverOneMiBIsRead(t *testing.T) {
	c := NewClient("gpt-x", "", longLineStub(t, 3<<20))
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
	assert.Equal(t, ai.ToolEvent{ID: "item_1", Name: "shell", Done: true, Result: "codex's report of this tool's result could not be read"}, tools[1])
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

// A top-level error event that the turn recovers from (codex's
// "Reconnecting…" retry notice) does not fail a turn that then completes.
func TestQuery_TransientErrorThenCompletedSucceeds(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"turn.started"}`,
		`{"type":"error","message":"Reconnecting... 1/5"}`,
		`{"type":"error","message":"Reconnecting... 2/5","error":{"message":"stream disconnected"}}`,
		`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"All good."}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	chunks, err := queryAll(t, NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0)))
	require.NoError(t, err)
	assert.Equal(t, "All good.", textOf(chunks))
}

// A tool item codex reports only once, at item.completed, is still one
// start and one end.
func TestQuery_ToolSeenOnlyAtCompletion(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"result":{"content":[{"type":"text","text":"[]"}]},"error":null,"status":"completed"}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Nothing open."}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	c := NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0))
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	var tools []ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil {
			tools = append(tools, *ch.Tool)
		}
	}
	assert.Equal(t, []ai.ToolEvent{
		{ID: "item_1", Name: "mcp__watchtower__list_targets", Args: json.RawMessage(`{}`)},
		{ID: "item_1", Name: "mcp__watchtower__list_targets", Done: true, OK: true, Result: "[]"},
	}, tools)
	assert.Equal(t, "Nothing open.", textOf(chunks))
}

// rawCodexScript writes a codex stub whose stdout is exactly stdout (printf,
// no trailing newline added). stdout is single-quoted: it must hold no '.
func rawCodexScript(t *testing.T, stdout string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fake CLI test skipped on windows")
	}
	require.NotContains(t, stdout, "'")
	path := filepath.Join(t.TempDir(), "codex")
	body := "#!/bin/sh\ncat > /dev/null\nprintf '%s' '" + stdout + "'\n"
	require.NoError(t, os.WriteFile(path, []byte(body), 0o755))
	return path
}

// codex's last line without a trailing newline (turn.completed here) is
// still read: the run completes.
func TestQuery_LastLineWithoutNewline(t *testing.T) {
	stdout := `{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Done."}}` + "\n" +
		`{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}`
	c := NewClient("gpt-x", "", rawCodexScript(t, stdout))
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	assert.Equal(t, "Done.", textOf(chunks))
	var usage []ai.TurnUsage
	for _, ch := range chunks {
		if ch.Usage != nil {
			usage = append(usage, *ch.Usage)
		}
	}
	assert.Equal(t, []ai.TurnUsage{{Model: "gpt-x", Tokens: llmusage.Tokens{Input: 10, Output: 2}}}, usage)
}

// A completed turn with no answer text fails like QuerySync and the batch
// generator do — except a chat turn (v2) whose steps are its whole reply:
// the chat shows those, as on Claude.
func TestQuery_CompletedTurnWithoutAnswer(t *testing.T) {
	toolOnly := strings.Join([]string{
		`{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"update_target","arguments":{},"result":{"content":[{"type":"text","text":"ok"}]},"error":null,"status":"completed"}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	t.Run("nothing at all", func(t *testing.T) {
		for _, v2 := range []bool{false, true} {
			c := NewClient("gpt-x", "", fakeCodexScript(t, `{"type":"turn.completed"}`, "", 0))
			if v2 {
				c.EmitToolEvents()
			}
			_, err := queryAll(t, c)
			require.ErrorIs(t, err, errNoAgentMessage, "v2=%v", v2)
			var failure *providers.Failure
			require.ErrorAs(t, err, &failure)
			assert.Equal(t, providers.InvalidOutput, failure.Category)
		}
	})
	t.Run("tools only, v1", func(t *testing.T) {
		_, err := queryAll(t, NewClient("gpt-x", "", fakeCodexScript(t, toolOnly, "", 0)))
		require.ErrorIs(t, err, errNoAgentMessage)
	})
	t.Run("tools only, v2", func(t *testing.T) {
		c := NewClient("gpt-x", "", fakeCodexScript(t, toolOnly, "", 0))
		c.EmitToolEvents()
		chunks, err := queryAll(t, c)
		require.NoError(t, err)
		assert.Empty(t, textOf(chunks))
	})
}

// An answer lost to a skipped (oversized) line never ends as a blank
// "complete" turn — not even a v2 one with tool steps, since the skipped
// line may have been the answer.
func TestQuery_SkippedAnswerFails(t *testing.T) {
	old := maxStreamLine
	maxStreamLine = 512
	t.Cleanup(func() { maxStreamLine = old })

	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"result":{"content":[{"type":"text","text":"[]"}]},"error":null,"status":"completed"}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"` + strings.Repeat("a", 2048) + `"}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	c := NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0))
	c.EmitToolEvents()
	_, err := queryAll(t, c)
	require.ErrorIs(t, err, errNoAgentMessage)
	assert.Contains(t, err.Error(), "1 line(s) over 512 bytes skipped")
}

// Undecodable JSONL lines are counted and logged as a count, never their
// content (FILES-01), in the stream and in the batch parse alike; a tool
// left open after unreadable lines is closed with a neutral reason.
func TestQuery_UndecodableLinesAreCounted(t *testing.T) {
	canary := logcanary.Text("jsonl")
	sink := logcanary.Capture(t)
	stdout := strings.Join([]string{
		`{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"status":"in_progress"}}`,
		`{"type":"item.completed","item":{"id":"item_1" ` + canary,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Partial."}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	c := NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0))
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	var last *ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil {
			last = ch.Tool
		}
	}
	require.NotNil(t, last)
	assert.Equal(t, ai.ToolEvent{ID: "item_1", Name: "mcp__watchtower__list_targets", Done: true, Result: "codex's report of this tool's result could not be read"}, *last)
	assert.Contains(t, sink.String(), "codex: 1 undecodable JSONL line(s)")

	_, _, err = NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0)).QuerySync(context.Background(), "sys", "hi", "")
	require.NoError(t, err)
	assert.Equal(t, 2, strings.Count(sink.String(), "codex: 1 undecodable JSONL line(s)"), "the batch parse logs its count too")
	sink.AssertClean(t)
}

// A stopped v2 turn still closes its open steps and streams the usage codex
// reported so far: the consumer, still draining, gets them after the stop.
func TestQuery_StoppedTurnStreamsItsEnd(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := filepath.Join(dir, "codex")
	body := `#!/bin/sh
echo $$ > '` + pidFile + `'
cat > /dev/null
echo '{"type":"turn.started"}'
echo '{"type":"usage","usage":{"input_tokens":50,"output_tokens":5}}'
echo '{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"status":"in_progress"}}'
exec sleep 30
`
	require.NoError(t, os.WriteFile(script, []byte(body), 0o755))
	t.Cleanup(func() { reapGroup(readPID(pidFile)) })

	c := NewClient("gpt-x", "", script)
	c.EmitToolEvents()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	textCh, errCh, sidCh := c.Query(ctx, "sys", "user", "")
	var tools []ai.ToolEvent
	var usage []ai.TurnUsage
	for ch := range textCh {
		if ch.Tool != nil {
			tools = append(tools, *ch.Tool)
			if !ch.Tool.Done {
				cancel() // the owner presses Stop once the step shows
			}
		}
		if ch.Usage != nil {
			usage = append(usage, *ch.Usage)
		}
	}
	for range sidCh {
	}
	var err error
	for e := range errCh {
		if err == nil {
			err = e
		}
	}
	require.ErrorIs(t, err, context.Canceled)
	require.Len(t, tools, 2)
	assert.Equal(t, ai.ToolEvent{ID: "item_1", Name: "mcp__watchtower__list_targets", Done: true, Result: "stopped before the tool finished"}, tools[1])
	assert.Equal(t, []ai.TurnUsage{{Model: "gpt-x", Tokens: llmusage.Tokens{Input: 50, Output: 5}}}, usage)
}

// Items without an id get a per-run one: two id-less tool calls stay two
// steps, each start paired with its end, and two id-less agent messages
// are still separated.
func TestQuery_ItemsWithoutID(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"type":"agent_message","text":"First."}}`,
		`{"type":"item.started","item":{"type":"command_execution","command":"ls","status":"in_progress"}}`,
		`{"type":"item.completed","item":{"type":"command_execution","command":"ls","aggregated_output":"a","exit_code":0,"status":"completed"}}`,
		`{"type":"item.started","item":{"type":"command_execution","command":"pwd","status":"in_progress"}}`,
		`{"type":"item.completed","item":{"type":"command_execution","command":"pwd","aggregated_output":"/w","exit_code":0,"status":"completed"}}`,
		`{"type":"item.completed","item":{"type":"agent_message","text":"Second."}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	c := NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0))
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	var tools []ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil {
			tools = append(tools, *ch.Tool)
		}
	}
	require.Len(t, tools, 4)
	assert.NotEmpty(t, tools[0].ID)
	assert.NotEqual(t, tools[0].ID, tools[2].ID)
	assert.Equal(t, []ai.ToolEvent{
		{ID: tools[0].ID, Name: "shell", Args: json.RawMessage(`{"command":"ls"}`)},
		{ID: tools[0].ID, Name: "shell", Done: true, OK: true, Result: "a"},
		{ID: tools[2].ID, Name: "shell", Args: json.RawMessage(`{"command":"pwd"}`)},
		{ID: tools[2].ID, Name: "shell", Done: true, OK: true, Result: "/w"},
	}, tools)
	assert.Equal(t, "First.\n\nSecond.", textOf(chunks))
}

// An empty answer after an undecodable line fails a v2 turn with tool
// steps too: the garbled line may have been the answer.
func TestQuery_UndecodableAnswerFails(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"result":{"content":[{"type":"text","text":"[]"}]},"error":null,"status":"completed"}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"cut`,
		`{"type":"turn.completed"}`,
	}, "\n")
	c := NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0))
	c.EmitToolEvents()
	_, err := queryAll(t, c)
	require.ErrorIs(t, err, errNoAgentMessage)
	assert.Contains(t, err.Error(), "1 undecodable")
}

// Two id-less tools open at once: each update and completion goes to the
// oldest open one, so starts and ends pair in codex's order.
func TestQuery_OverlappingToolsWithoutID(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"item.started","item":{"type":"command_execution","command":"ls","status":"in_progress"}}`,
		`{"type":"item.started","item":{"type":"command_execution","command":"pwd","status":"in_progress"}}`,
		`{"type":"item.updated","item":{"type":"command_execution","command":"ls","status":"in_progress"}}`,
		`{"type":"item.completed","item":{"type":"command_execution","command":"ls","aggregated_output":"a","exit_code":0,"status":"completed"}}`,
		`{"type":"item.completed","item":{"type":"command_execution","command":"pwd","aggregated_output":"/w","exit_code":0,"status":"completed"}}`,
		`{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"Done."}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
	c := NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0))
	c.EmitToolEvents()
	chunks, err := queryAll(t, c)
	require.NoError(t, err)
	var tools []ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil {
			tools = append(tools, *ch.Tool)
		}
	}
	require.Len(t, tools, 4)
	ls, pwd := tools[0].ID, tools[1].ID
	assert.NotEqual(t, ls, pwd)
	assert.Equal(t, []ai.ToolEvent{
		{ID: ls, Name: "shell", Args: json.RawMessage(`{"command":"ls"}`)},
		{ID: pwd, Name: "shell", Args: json.RawMessage(`{"command":"pwd"}`)},
		{ID: ls, Name: "shell", Done: true, OK: true, Result: "a"},
		{ID: pwd, Name: "shell", Done: true, OK: true, Result: "/w"},
	}, tools)
}
