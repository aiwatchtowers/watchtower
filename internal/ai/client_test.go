package ai

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/digest"
)

// writeMockClaude creates a shell script that mimics the claude CLI for testing.
func writeMockClaude(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "claude")
	err := os.WriteFile(path, []byte("#!/bin/sh\n"+script), 0o755)
	require.NoError(t, err)
	return path
}

func TestNewClient_DefaultClaudeCmd(t *testing.T) {
	c := NewClient("model", "", "")
	assert.Contains(t, c.claudeCmd, "claude")
	assert.Equal(t, "model", c.model)
}

func TestBuildArgs(t *testing.T) {
	c := NewClient("claude-sonnet-4-6", "", "")
	args, stdin, _ := c.buildArgs("system prompt", "user message", "text", "")
	assert.Empty(t, stdin)

	assert.Contains(t, args, "-p")
	assert.Contains(t, args, "user message")
	assert.Contains(t, args, "--system-prompt")
	assert.Contains(t, args, "system prompt")
	assert.Contains(t, args, "--output-format")
	assert.Contains(t, args, "text")
	assert.Contains(t, args, "--model")
	assert.Contains(t, args, "claude-sonnet-4-6")
	// Read-only tool allowlist: only the watchtower MCP server, which is
	// read-only by construction (its stdio connection runs query_only, see
	// cmd/mcp.go). Prompt-injection from synced Slack/Jira content must not
	// reach a shell, so the allowlist must NOT grant Bash access.
	assertFlagValue(t, args, "--allowedTools", "mcp__watchtower")
	allowed := allowedToolsValue(t, args)
	assert.NotContains(t, allowed, "Bash(")
	assert.Equal(t, "mcp__watchtower", allowed)
	// Built-ins are hidden outright (not merely denied) so the model never
	// wastes a turn calling them and asking the user for approvals: file
	// editing and Claude Code task tooling, shell and web (live sources +
	// exfiltration channel), and filesystem reads (TCC prompt risk).
	assertFlagValue(t, args, "--disallowedTools", DisallowedTools)
	for _, tool := range []string{"Edit", "Bash", "WebFetch", "Read", "Skill", "CronCreate", "RemoteTrigger",
		"Workflow", "SendMessage", "ReadMcpResourceTool", "ListMcpResourcesTool"} {
		assert.Contains(t, strings.Split(DisallowedTools, ","), tool)
	}
	assert.NotContains(t, strings.Split(DisallowedTools, ","), "ToolSearch",
		"ToolSearch loads the deferred watchtower tools and must stay allowed")
	// Only Watchtower's own MCP config: never the owner's claude.ai connectors.
	assert.Contains(t, args, "--strict-mcp-config")
	// TCC isolation: every spawn must skip user-level ~/.claude/settings.json
	// via --setting-sources project,local. Dropping this re-opens the P0 where
	// plugin/hook auto-discovery probes ~/Desktop and triggers a Watchtower.app
	// TCC prompt. Assert the flag AND its value adjacency so a refactor can't
	// silently drop or split the pair.
	assertFlagValue(t, args, "--setting-sources", "project,local")
	assert.NotContains(t, args, "--resume")
}

// allowedToolsValue returns the value passed to --allowedTools, failing if absent.
func allowedToolsValue(t *testing.T, args []string) string {
	t.Helper()
	for i, a := range args {
		if a == "--allowedTools" && i+1 < len(args) {
			return args[i+1]
		}
	}
	t.Fatal("--allowedTools not found in args")
	return ""
}

// assertFlagValue verifies flag is present in args and immediately followed by value.
func assertFlagValue(t *testing.T, args []string, flag, value string) {
	t.Helper()
	for i, a := range args {
		if a == flag {
			if assert.Less(t, i+1, len(args), "%s has no value", flag) {
				assert.Equal(t, value, args[i+1], "%s value", flag)
			}
			return
		}
	}
	t.Errorf("flag %s not found in args %v", flag, args)
}

// flagValue returns the token immediately following flag in args, failing
// the test if the flag is absent or has no following value.
func flagValue(t *testing.T, args []string, flag string) string {
	t.Helper()
	for i, a := range args {
		if a == flag {
			if i+1 < len(args) {
				return args[i+1]
			}
			t.Fatalf("flag %s has no value", flag)
		}
	}
	t.Fatalf("flag %s not found in args %v", flag, args)
	return ""
}

func TestBuildArgs_WithDBPath(t *testing.T) {
	c := NewClient("claude-sonnet-4-6", "/tmp/test.db", "")
	args, _, _ := c.buildArgs("system prompt", "user message", "text", "")

	assert.Contains(t, args, "--mcp-config")
	// The MCP server is the watchtower binary itself running `mcp --db-path`,
	// NOT a third-party npx package. Verify the config points at our binary and
	// the given DB path.
	found := false
	for i, a := range args {
		if a == "--mcp-config" && i+1 < len(args) {
			found = true
			cfg := args[i+1]
			assert.Contains(t, cfg, "/tmp/test.db")
			assert.Contains(t, cfg, "mcpServers")
			assert.Contains(t, cfg, "watchtower")
			assert.Contains(t, cfg, "\"mcp\"")
			assert.Contains(t, cfg, "--db-path")
			assert.NotContains(t, cfg, "npx")
			assert.NotContains(t, cfg, "mcp-server-sqlite")
		}
	}
	assert.True(t, found, "--mcp-config must be present with a db path")
}

func TestBuildArgs_WithoutDBPath(t *testing.T) {
	c := NewClient("claude-sonnet-4-6", "", "")
	args, _, _ := c.buildArgs("system prompt", "user message", "text", "")

	assert.NotContains(t, args, "--mcp-config")
}

func TestBuildArgs_WithSessionID(t *testing.T) {
	c := NewClient("claude-sonnet-4-6", "", "")
	args, _, _ := c.buildArgs("system prompt", "user message", "stream-json", "session-123")

	assert.Contains(t, args, "--resume")
	assert.Contains(t, args, "session-123")
	assert.NotContains(t, args, "--system-prompt")
}

// TestBuildArgs_LeadingDashPromptGoesToStdin pins the leading-dash guard on
// promptFlagAndStdin: a chat message beginning with '-' must never sit
// inline after "-p" (claude's --print takes an OPTIONAL value, so a
// following dash-led token would be parsed as a new flag instead of being
// consumed as -p's value) even though it is far below StdinThreshold.
func TestBuildArgs_LeadingDashPromptGoesToStdin(t *testing.T) {
	c := NewClient("claude-sonnet-4-6", "", "")
	msg := "-v looks wrong"
	args, stdin, _ := c.buildArgs("sys", msg, "text", "")
	if stdin != msg {
		t.Fatalf("stdin = %q, want the leading-dash message", stdin)
	}
	pIdx := -1
	for i, a := range args {
		if a == "-p" {
			pIdx = i
			break
		}
	}
	if pIdx == -1 {
		t.Fatal("args has no -p flag")
	}
	if pIdx+1 >= len(args) || !strings.HasPrefix(args[pIdx+1], "--") {
		t.Errorf("token after -p = %q, want a flag (message must not be inline)", args[pIdx+1])
	}
	for _, a := range args {
		if a == msg {
			t.Error("args contains the leading-dash message; it must travel via stdin only")
		}
	}
}

// TestBuildArgs_StdinThresholdBoundary pins the exact-threshold boundary so
// the inline and stdin routes never both fire: a message of exactly
// StdinThreshold bytes stays inline, one byte over routes to stdin.
func TestBuildArgs_StdinThresholdBoundary(t *testing.T) {
	c := NewClient("claude-sonnet-4-6", "", "")

	exact := strings.Repeat("x", digest.StdinThreshold)
	args, stdin, _ := c.buildArgs("sys", exact, "text", "")
	if stdin != "" {
		t.Errorf("stdin = %d bytes, want empty: exactly StdinThreshold stays inline", len(stdin))
	}
	assertFlagValue(t, args, "-p", exact)

	over := exact + "x"
	args2, stdin2, _ := c.buildArgs("sys", over, "text", "")
	if stdin2 != over {
		t.Errorf("stdin length = %d, want the full over-threshold message", len(stdin2))
	}
	for _, a := range args2 {
		if a == over {
			t.Error("over-threshold message must not appear inline in args")
		}
	}
	// "-p" must be bare on the stdin route: the next token must be a flag,
	// never a value (an implementation that swaps the message for "" and
	// still passes it inline, e.g. "-p" ""), would pass the two checks
	// above while still being wrong.
	pIdx := -1
	for i, a := range args2 {
		if a == "-p" {
			pIdx = i
			break
		}
	}
	if pIdx == -1 {
		t.Fatal("args2 has no -p flag")
	}
	if pIdx+1 >= len(args2) || !strings.HasPrefix(args2[pIdx+1], "--") {
		t.Errorf("token after -p = %q, want a flag (message must not be inline, even as an empty value)", args2[pIdx+1])
	}
}

// TestQuerySync_LeadingDashMessageReachesStdin proves the leading-dash route
// wires all the way to the subprocess for QuerySync: a fake claude binary
// reads its stdin and echoes a marker back only when it finds it there.
func TestQuerySync_LeadingDashMessageReachesStdin(t *testing.T) {
	const marker = "STDIN-MARKER-ai-client-sync-01"
	mockPath := writeMockClaude(t, `input=$(cat)
case "$input" in
*`+marker+`*) printf '{"type":"result","result":"got:`+marker+`"}' ;;
*) printf '{"type":"result","result":"marker-missing"}' ;;
esac
`)
	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	msg := "-v " + marker
	result, _, err := c.QuerySync(context.Background(), "system", msg, "")
	require.NoError(t, err)
	assert.Equal(t, "got:"+marker, result, "the leading-dash message did not reach the subprocess via stdin")
}

// TestQuery_LeadingDashMessageReachesStdin is QuerySync's streaming sibling:
// the leading-dash route must also be wired on the Query call site.
func TestQuery_LeadingDashMessageReachesStdin(t *testing.T) {
	const marker = "STDIN-MARKER-ai-client-stream-02"
	script := `input=$(cat)
case "$input" in
*` + marker + `*) printf '{"type":"assistant","message":{"content":[{"type":"text","text":"got:` + marker + `"}]}}\n' ;;
*) printf '{"type":"assistant","message":{"content":[{"type":"text","text":"marker-missing"}]}}\n' ;;
esac
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	msg := "-v " + marker
	textCh, errCh, _ := c.Query(context.Background(), "system", msg, "")

	var result strings.Builder
	for chunk := range textCh {
		result.WriteString(chunk.Text)
	}
	require.NoError(t, <-errCh)
	assert.Equal(t, "got:"+marker, result.String(), "the leading-dash message did not reach the subprocess via stdin")
}

func TestQuerySync_Success(t *testing.T) {
	mockPath := writeMockClaude(t, `printf '{"type":"result","result":"Hello from Claude","usage":{"input_tokens":10,"output_tokens":5},"total_cost_usd":0.001}'`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	result, usage, err := c.QuerySync(context.Background(), "system", "hello", "")
	require.NoError(t, err)
	assert.Equal(t, "Hello from Claude", result)
	require.NotNil(t, usage)
	assert.Equal(t, 10, usage.InputTokens)
	assert.Equal(t, 5, usage.OutputTokens)
}

func TestQuerySync_TrimsTrailingNewlines(t *testing.T) {
	mockPath := writeMockClaude(t, `printf '{"type":"result","result":"response\\n\\n","usage":{"input_tokens":1,"output_tokens":1}}'`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	result, _, err := c.QuerySync(context.Background(), "system", "hello", "")
	require.NoError(t, err)
	assert.Equal(t, "response", result)
}

func TestQuerySync_ExitError(t *testing.T) {
	mockPath := writeMockClaude(t, `echo "something went wrong" >&2; exit 1`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	_, _, err := c.QuerySync(context.Background(), "system", "hello", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "claude CLI failed")
	assert.Contains(t, err.Error(), "something went wrong")
}

// TestQuerySync_ExitErrorSurfacesEnvelopeMessage pins that a failed run whose
// stderr is empty (the CLI reports an API/usage failure as an ordinary result
// envelope on stdout and exits 1) surfaces the envelope's own actionable
// message instead of a bare "claude CLI failed with exit code 1" — the
// digest generator's already-reviewed precedent (internal/digest/generator.go).
func TestQuerySync_ExitErrorSurfacesEnvelopeMessage(t *testing.T) {
	mockPath := writeMockClaude(t, `printf '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key. Please run /login"}'; exit 1`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	_, _, err := c.QuerySync(context.Background(), "system", "hello", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Invalid API key")
	assert.Contains(t, err.Error(), "Please run /login")
	assert.Contains(t, err.Error(), "error_during_execution")
}

// TestQuerySync_ExitErrorFallsBackWhenOutputUnparsable is the degenerate
// counterpart: a non-zero exit whose stdout is not a result envelope at all
// (empty, or garbage) must still fall back to the ordinary stderr-based
// classifyError path rather than panicking or losing the exit code.
func TestQuerySync_ExitErrorFallsBackWhenOutputUnparsable(t *testing.T) {
	mockPath := writeMockClaude(t, `echo "network unreachable" >&2; exit 1`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	_, _, err := c.QuerySync(context.Background(), "system", "hello", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "claude CLI failed")
	assert.Contains(t, err.Error(), "network unreachable")
}

// TestQuerySync_CleanExitIsErrorSurfacesEnvelopeMessage pins the exit-0 case:
// the CLI can flag is_error in the envelope while still exiting 0, and that
// message must reach the caller with the same subtype/truncation handling.
func TestQuerySync_CleanExitIsErrorSurfacesEnvelopeMessage(t *testing.T) {
	mockPath := writeMockClaude(t, `printf '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"ran out of turns"}'`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	_, _, err := c.QuerySync(context.Background(), "system", "hello", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "ran out of turns")
	assert.Contains(t, err.Error(), "error_max_turns")
}

func TestQuerySync_ContextCancellation(t *testing.T) {
	mockPath := writeMockClaude(t, `sleep 10; echo "too late"`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	_, _, err := c.QuerySync(ctx, "system", "hello", "")
	require.Error(t, err)
}

func TestQuery_StreamingSuccess(t *testing.T) {
	// Mock script outputs stream-json events
	script := `
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello "}]}}\n'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"world!"}]}}\n'
printf '{"type":"result","subtype":"success","result":"Hello world!","session_id":"sess-abc"}\n'
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, sidCh := c.Query(context.Background(), "system", "hello", "")

	var result strings.Builder
	for chunk := range textCh {
		result.WriteString(chunk.Text)
	}

	err := <-errCh
	require.NoError(t, err)
	assert.Equal(t, "Hello world!", result.String())

	sid := <-sidCh
	assert.Equal(t, "sess-abc", sid)
}

// A tool call mid-turn must surface as a boundary chunk, and the "let me check
// first" preamble streamed before it must not glue onto the post-tool answer —
// the desktop bug where "I need to check…first.Да, могу…" rendered as one line.
func TestQuery_ToolUseSignalsBoundaryAndDropsPreamble(t *testing.T) {
	script := `
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"I need to check the projects first."}]}}\n'
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"list_jira_projects","input":{}}]}}\n'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Here is the answer."}]}}\n'
printf '{"type":"result","subtype":"success","result":"Here is the answer.","session_id":"sess-1"}\n'
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, _ := c.Query(context.Background(), "system", "hi", "")

	var chunks []StreamChunk
	// Replay the consumer's reset-on-boundary contract (cmd/ai.go → desktop).
	var visible strings.Builder
	sawBoundary := false
	for chunk := range textCh {
		chunks = append(chunks, chunk)
		if chunk.ToolBoundary {
			sawBoundary = true
			visible.Reset()
			continue
		}
		visible.WriteString(chunk.Text)
	}

	require.NoError(t, <-errCh)
	assert.True(t, sawBoundary, "a tool_use event must emit a boundary chunk")
	assert.Equal(t, "Here is the answer.", visible.String(),
		"the pre-tool preamble must be dropped, not glued to the answer")
	// The preamble did reach the stream (so live UI can show it), but as its own
	// chunk before the boundary — never concatenated with the answer.
	require.GreaterOrEqual(t, len(chunks), 3)
	assert.Equal(t, "I need to check the projects first.", chunks[0].Text)
	assert.True(t, chunks[1].ToolBoundary)
}

func TestQuery_StreamingIgnoresNonTextEvents(t *testing.T) {
	script := `
printf '{"type":"system","subtype":"init","session_id":"test"}\n'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"response"}]}}\n'
printf '{"type":"result","subtype":"success","result":"response","session_id":"sess-xyz"}\n'
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")

	var result strings.Builder
	for chunk := range textCh {
		result.WriteString(chunk.Text)
	}

	err := <-errCh
	require.NoError(t, err)
	assert.Equal(t, "response", result.String())
}

func TestQuery_StreamingError(t *testing.T) {
	mockPath := writeMockClaude(t, `echo "error occurred" >&2; exit 1`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")

	for range textCh {
	}

	err := <-errCh
	require.Error(t, err)
	assert.Contains(t, err.Error(), "claude CLI failed")
}

// TestQuery_StreamingExitErrorSurfacesEnvelopeMessage is Query's streaming
// sibling of TestQuerySync_ExitErrorSurfacesEnvelopeMessage: a "result" event
// with is_error:true reaches stdout before a non-zero exit with empty
// stderr, and that message must reach errCh instead of a bare exit code.
func TestQuery_StreamingExitErrorSurfacesEnvelopeMessage(t *testing.T) {
	script := `
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}\n'
printf '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key. Please run /login"}\n'
exit 1
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")
	for range textCh {
	}

	err := <-errCh
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Invalid API key")
	assert.Contains(t, err.Error(), "Please run /login")
	assert.Contains(t, err.Error(), "error_during_execution")
}

// TestQuery_StreamingCleanExitIsErrorSurfacesEnvelopeMessage pins the exit-0
// counterpart: the CLI can flag is_error in the result event while the
// process still exits 0, and Query must still surface it as an error rather
// than a silent success with an empty answer.
func TestQuery_StreamingCleanExitIsErrorSurfacesEnvelopeMessage(t *testing.T) {
	script := `
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"ran out of turns"}\n'
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")
	for range textCh {
	}

	err := <-errCh
	require.Error(t, err)
	assert.Contains(t, err.Error(), "ran out of turns")
	assert.Contains(t, err.Error(), "error_max_turns")
}

// TestQuery_StreamingExitErrorFallsBackWhenNoResultEvent is the degenerate
// clean-exit counterpart on the streaming path: a non-zero exit with no
// "result" event at all (e.g. the process died before emitting one) must
// still fall back to the ordinary stderr-based classifyError path.
func TestQuery_StreamingExitErrorFallsBackWhenNoResultEvent(t *testing.T) {
	mockPath := writeMockClaude(t, `echo "error occurred" >&2; exit 1`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")
	for range textCh {
	}

	err := <-errCh
	require.Error(t, err)
	assert.Contains(t, err.Error(), "claude CLI failed")
	assert.Contains(t, err.Error(), "error occurred")
}

func TestQuery_ContextCancellation(t *testing.T) {
	mockPath := writeMockClaude(t, `sleep 10`)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	textCh, errCh, _ := c.Query(ctx, "system", "hello", "")

	for range textCh {
	}

	err := <-errCh
	if err != nil {
		// Either context error, kill error, or pipe read error is acceptable
		msg := err.Error()
		assert.True(t, strings.Contains(msg, "context") ||
			strings.Contains(msg, "signal") ||
			strings.Contains(msg, "killed") ||
			strings.Contains(msg, "claude CLI") ||
			strings.Contains(msg, "reading claude output"),
			"unexpected error: %s", msg)
	}
}

func TestQuery_SessionIDFromResultEvent(t *testing.T) {
	script := `
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}\n'
printf '{"type":"result","subtype":"success","result":"hi","session_id":"new-session-42"}\n'
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, sidCh := c.Query(context.Background(), "system", "hello", "")

	for range textCh {
	}
	require.NoError(t, <-errCh)

	sid := <-sidCh
	assert.Equal(t, "new-session-42", sid)
}

func TestQuery_NoSessionIDWhenMissing(t *testing.T) {
	script := `
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}\n'
printf '{"type":"result","subtype":"success","result":"hi"}\n'
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, sidCh := c.Query(context.Background(), "system", "hello", "")

	for range textCh {
	}
	require.NoError(t, <-errCh)

	// Channel should be closed with no value
	sid, ok := <-sidCh
	assert.False(t, ok)
	assert.Empty(t, sid)
}

func TestClassifyError_NotFound(t *testing.T) {
	err := classifyError(&exec.Error{Name: "claude", Err: exec.ErrNotFound}, "")
	assert.Contains(t, err.Error(), "claude CLI not found")
}

func TestClassifyError_ExitError(t *testing.T) {
	err := classifyError(&exec.ExitError{}, "auth failed")
	assert.Contains(t, err.Error(), "claude CLI failed")
	assert.Contains(t, err.Error(), "auth failed")
}

func TestStreamEvent_ExtractText(t *testing.T) {
	tests := []struct {
		name     string
		event    streamEvent
		expected string
	}{
		{"assistant message", streamEvent{Type: "assistant", Message: &streamMessage{Content: []streamContent{{Type: "text", Text: "hello"}}}}, "hello"},
		{"result event", streamEvent{Type: "result", Subtype: "success", Result: "full"}, ""},
		{"system event", streamEvent{Type: "system", Subtype: "init"}, ""},
		{"assistant no message", streamEvent{Type: "assistant"}, ""},
		{"assistant empty content", streamEvent{Type: "assistant", Message: &streamMessage{}}, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.expected, tt.event.extractText())
		})
	}
}

func TestQuery_IgnoresMalformedJSON(t *testing.T) {
	script := `
printf 'not json\n'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"valid"}]}}\n'
printf '{broken json\n'
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")

	var result strings.Builder
	for chunk := range textCh {
		result.WriteString(chunk.Text)
	}

	err := <-errCh
	require.NoError(t, err)
	assert.Equal(t, "valid", result.String())
}

func TestQuery_SkipsEmptyLines(t *testing.T) {
	script := `
printf '\n'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"data"}]}}\n'
printf '\n'
`
	mockPath := writeMockClaude(t, script)

	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	textCh, errCh, _ := c.Query(context.Background(), "system", "hello", "")

	var result strings.Builder
	for chunk := range textCh {
		result.WriteString(chunk.Text)
	}

	err := <-errCh
	require.NoError(t, err)
	assert.Equal(t, "data", result.String())
}

// TestParseCLIOutput_UnparsableOutputIsNotEchoed pins that the parse error
// describes the CLI output instead of quoting it. The output is model text
// built from private Slack/mail/calendar content, and this error is wrapped
// with %w into the daemon log, pipeline_runs.error_msg, and the Desktop UI.
func TestParseCLIOutput_UnparsableOutputIsNotEchoed(t *testing.T) {
	secret := "Northwind acquisition closes Friday, legal still reviewing the terms"

	_, err := parseCLIOutput([]byte(secret))
	require.Error(t, err)

	assert.NotContains(t, err.Error(), secret)
	assert.NotContains(t, err.Error(), "Northwind")
	// Still diagnostic: shape, size, and a correlatable fingerprint.
	assert.Contains(t, err.Error(), "unexpected claude CLI output format")
	assert.Contains(t, err.Error(), "looks like plain text")
	assert.Contains(t, err.Error(), "sha256:")
}

func TestEnvelopeMessage_EmptyResultGetsPlaceholder(t *testing.T) {
	assert.Equal(t, "no message in the CLI result envelope", envelopeMessage("   "))
}

func TestEnvelopeMessage_ShortResultPassesThrough(t *testing.T) {
	assert.Equal(t, "Invalid API key", envelopeMessage("  Invalid API key  "))
}

// TestEnvelopeMessage_TruncatesAtRuneBoundary pins that an oversized envelope
// message (subtype=error_max_turns can carry the model's own partial output,
// routinely multi-byte Cyrillic) is capped rather than logged/surfaced in
// full, and that the cut never lands mid-rune.
func TestEnvelopeMessage_TruncatesAtRuneBoundary(t *testing.T) {
	long := strings.Repeat("привет ", 1000) // well past the 4096-byte cap, all multi-byte runes
	got := envelopeMessage(long)
	assert.Less(t, len(got), len(long))
	assert.Contains(t, got, "truncated")
	assert.True(t, utf8.ValidString(got), "truncated message must not cut a rune in half")
}

func TestBuildMCPConfig_IncludesExtraArgs(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	c.SetMCPArgs([]string{"--chat", "--surface", "main", "--conversation", "12", "--turn", "abc"})
	cfg := c.buildMCPConfig()
	var parsed struct {
		Servers map[string]struct {
			Args []string `json:"args"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(cfg), &parsed); err != nil {
		t.Fatal(err)
	}
	got := parsed.Servers["watchtower"].Args
	want := []string{"mcp", "--db-path", "/tmp/w.db", "--chat", "--surface", "main", "--conversation", "12", "--turn", "abc"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args = %v, want %v", got, want)
	}
}

func TestBuildMCPConfig_MergesExternalServers(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	c.SetExternalMCPServers([]ExternalMCPServer{{
		Name: "trello", Kind: "stdio", Command: "npx", Args: []string{"-y", "trello-mcp"},
		Env: map[string]string{"K": "v"},
	}})
	var parsed struct {
		Servers map[string]struct {
			Command string            `json:"command"`
			Args    []string          `json:"args"`
			Env     map[string]string `json:"env"`
			URL     string            `json:"url"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(c.buildMCPConfig()), &parsed); err != nil {
		t.Fatal(err)
	}
	if _, ok := parsed.Servers["watchtower"]; !ok {
		t.Fatal("watchtower server missing")
	}
	tr, ok := parsed.Servers["trello"]
	if !ok || tr.Command != "npx" || tr.Env["K"] != "v" {
		t.Fatalf("trello = %+v", tr)
	}
}

// TestBuildMCPConfig_HTTPServerShape is a characterization guard: it pins the
// http-transport entry shape externalServerConfig already emits
// ({"type":"http","url":...,"headers":...}), asserting no stdio keys
// (command/args/env) leak into it and that the allowlist still gains the
// mcp__<name> token like the stdio path.
func TestBuildMCPConfig_HTTPServerShape(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	c.SetExternalMCPServers([]ExternalMCPServer{{
		Name: "acme", Kind: "http", URL: "https://acme.example/mcp",
		Headers: map[string]string{"Authorization": "Bearer tok"},
	}})
	var parsed struct {
		Servers map[string]struct {
			Type    string            `json:"type"`
			URL     string            `json:"url"`
			Headers map[string]string `json:"headers"`
			Command *string           `json:"command"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(c.buildMCPConfig()), &parsed); err != nil {
		t.Fatal(err)
	}
	acme, ok := parsed.Servers["acme"]
	if !ok {
		t.Fatal("acme server missing")
	}
	if acme.Type != "http" {
		t.Fatalf("type = %q, want http", acme.Type)
	}
	if acme.URL != "https://acme.example/mcp" {
		t.Fatalf("url = %q", acme.URL)
	}
	if !reflect.DeepEqual(acme.Headers, map[string]string{"Authorization": "Bearer tok"}) {
		t.Fatalf("headers = %v", acme.Headers)
	}
	if acme.Command != nil {
		t.Fatalf("command = %v, want nil (no stdio keys on an http entry)", acme.Command)
	}

	args, _, _ := c.buildArgs("sys", "hi", "json", "")
	assertFlagValue(t, args, "--allowedTools", "mcp__watchtower")
}

// TestBuildMCPConfig_HTTPServerOmitsEmptyHeaders pins that an http server with
// no headers emits exactly {type, url}: no "headers" key (rather than an empty
// object) and no stdio keys (command/args/env) leaking into an http entry.
func TestBuildMCPConfig_HTTPServerOmitsEmptyHeaders(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	c.SetExternalMCPServers([]ExternalMCPServer{{
		Name: "acme", Kind: "http", URL: "https://acme.example/mcp",
	}})
	var parsed struct {
		Servers map[string]map[string]json.RawMessage `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(c.buildMCPConfig()), &parsed); err != nil {
		t.Fatal(err)
	}
	acme, ok := parsed.Servers["acme"]
	if !ok {
		t.Fatal("acme server missing")
	}
	if len(acme) != 2 {
		t.Fatalf("http entry must carry exactly type+url, got %d keys: %v", len(acme), acme)
	}
	for _, key := range []string{"type", "url"} {
		if _, ok := acme[key]; !ok {
			t.Fatalf("http entry missing %q key: %v", key, acme)
		}
	}
}

// TestBuildArgs_ExternalToolsAllowedPerTool pins QC-02: an external server
// is never granted whole (`mcp__trello`); only its allowed tools are, each as
// mcp__<server>__<tool>, and its other listed tools are hidden outright via
// --disallowedTools. A hostile tool name cannot inject an extra token.
func TestBuildArgs_ExternalToolsAllowedPerTool(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	c.SetExternalMCPServers([]ExternalMCPServer{{
		Name: "trello", Kind: "stdio", Command: "npx",
		AllowTools: []string{"list_boards", "get card,Bash"},
		DenyTools:  []string{"create_card"},
	}})
	args, _, _ := c.buildArgs("sys", "hi", "json", "")
	assertFlagValue(t, args, "--allowedTools", "mcp__watchtower,mcp__trello__list_boards,mcp__trello__get_card_Bash")
	assertFlagValue(t, args, "--disallowedTools", DisallowedTools+",mcp__trello__create_card")

	for _, a := range strings.Split(flagValue(t, args, "--allowedTools"), ",") {
		assert.NotEqual(t, "mcp__trello", a, "the whole server must never be granted")
	}
}

func TestBuildArgs_NoExternalDenyKeepsDisallowedTools(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	c.SetExternalMCPServers([]ExternalMCPServer{{Name: "trello", Kind: "stdio", Command: "npx", AllowTools: []string{"list_boards"}}})
	args, _, _ := c.buildArgs("sys", "hi", "json", "")
	assertFlagValue(t, args, "--disallowedTools", DisallowedTools)
}

func TestBuildMCPConfig_ZeroExternalUnchanged(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	// no SetExternalMCPServers call
	got := c.buildMCPConfig()
	if strings.Contains(got, "trello") || strings.Count(got, "\"command\"") != 1 {
		t.Fatalf("expected single watchtower server, got %s", got)
	}
}

func TestBuildArgs_NoAllowedToolsFlagLeak(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	args, _, _ := c.buildArgs("sys", "hi", "stream-json", "")
	for _, a := range args {
		if a == "--allowed-tools" {
			t.Fatalf("legacy flag leaked into claude args")
		}
	}
}

func TestMCPConfigDelivery_SecretGoesToFileNotArgv(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	c.SetExternalMCPServers([]ExternalMCPServer{{
		Name: "trello", Kind: "stdio", Command: "npx", Env: map[string]string{"TOKEN": "secret123"},
	}})
	args, _, _ := c.buildArgs("sys", "hi", "json", "")
	val := flagValue(t, args, "--mcp-config") // helper: returns the token after the flag
	t.Cleanup(func() { _ = os.Remove(val) })  // buildArgs writes a real 0600 temp file; normally removed by Query/QuerySync after cmd.Wait()
	if strings.Contains(strings.Join(args, " "), "secret123") {
		t.Fatal("secret leaked into argv")
	}
	// when a secret is present the value is a path to an existing 0600 file
	fi, err := os.Stat(val)
	if err != nil {
		t.Fatalf("mcp-config not a file: %v", err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", fi.Mode().Perm())
	}
}

func TestMCPConfigDelivery_NoSecretStaysInline(t *testing.T) {
	c := NewClient("sonnet", "/tmp/w.db", "")
	args, _, _ := c.buildArgs("sys", "hi", "json", "")
	val := flagValue(t, args, "--mcp-config")
	if !strings.HasPrefix(strings.TrimSpace(val), "{") {
		t.Fatalf("expected inline JSON, got %q", val)
	}
}

// The warm chat session builds its MCP config with the exported helpers; they
// must render exactly what the one-shot client sends, so `ai query` and
// `ai session` expose the same tools.
func TestChatMCPConfig_MatchesClient(t *testing.T) {
	ext := []ExternalMCPServer{{Name: "confluence", Kind: "http", URL: "https://mcp.example.com",
		AllowTools: []string{"search"}, DenyTools: []string{"createPage"}}}
	args := []string{"--chat", "--surface", "main", "--conversation", "7", "--turn-file", "/tmp/t"}
	c := NewClient("m", "/tmp/wt.db", "")
	c.SetMCPArgs(args)
	c.SetExternalMCPServers(ext)

	assert.Equal(t, c.buildMCPConfig(), ChatMCPConfig("/tmp/wt.db", args, ext))
	assert.Equal(t, c.allowedToolsFlag(), AllowedTools(ext))
	assert.Equal(t, "mcp__watchtower,mcp__confluence__search", AllowedTools(ext))
	assert.Equal(t, "Edit,mcp__confluence__createPage", WithExternalDisallowed("Edit", ext))
	assert.Contains(t, DisallowedTools, "Bash")
	assert.Contains(t, DisallowedTools, "WebFetch")
}

// The warm main-chat session unhides WebSearch only; WebFetch (arbitrary URL
// fetch, the exfiltration channel) stays hidden there, and the one-shot
// chats keep both hidden.
func TestSessionDisallowedTools_UnhidesOnlyWebSearch(t *testing.T) {
	session := strings.Split(SessionDisallowedTools, ",")
	oneShot := strings.Split(DisallowedTools, ",")
	assert.NotContains(t, session, WebSearchTool)
	assert.Contains(t, oneShot, WebSearchTool)
	assert.Contains(t, session, "WebFetch")
	assert.Contains(t, session, "Bash")
	assert.ElementsMatch(t, append(session, WebSearchTool), oneShot)
}

// TestBuildArgs_LargeSystemPromptGoesToFile: a system prompt above
// digest.StdinThreshold (the briefing / target-extract payloads) travels as a
// 0600 --system-prompt-file, never on argv (ARG_MAX, `ps`); a small one stays
// inline.
func TestBuildArgs_LargeSystemPromptGoesToFile(t *testing.T) {
	c := NewClient("m", "", "")
	big := strings.Repeat("s", digest.StdinThreshold+1)
	args, _, err := c.buildArgs(big, "hi", "json", "")
	require.NoError(t, err)
	promptPath := c.systemPromptTempPath
	t.Cleanup(func() { os.Remove(promptPath) })

	assert.NotContains(t, args, "--system-prompt")
	assert.NotContains(t, args, big)
	assertFlagValue(t, args, "--system-prompt-file", promptPath)
	info, err := os.Stat(promptPath)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	data, err := os.ReadFile(promptPath)
	require.NoError(t, err)
	assert.Equal(t, big, string(data))

	exact := strings.Repeat("s", digest.StdinThreshold)
	args, _, _ = c.buildArgs(exact, "hi", "json", "")
	assertFlagValue(t, args, "--system-prompt", exact)
	assert.Empty(t, c.systemPromptTempPath, "a small prompt must not leave a stale temp path behind")
}

// TestQuerySync_LargeSystemPromptReachesCLIAndFileIsRemoved wires the file
// path end to end: the mock CLI reads the prompt from --system-prompt-file,
// and the file is gone once QuerySync returns.
func TestQuerySync_LargeSystemPromptReachesCLIAndFileIsRemoved(t *testing.T) {
	const marker = "SYSPROMPT-MARKER-ai-03"
	mockPath := writeMockClaude(t, `file=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--system-prompt-file" ]; then file="$2"; fi
  shift
done
if [ -n "$file" ] && grep -q `+marker+` "$file"; then
  printf '{"type":"result","result":"got:`+marker+`"}'
else
  printf '{"type":"result","result":"marker-missing"}'
fi
`)
	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	sys := strings.Repeat("x", digest.StdinThreshold) + marker
	result, _, err := c.QuerySync(context.Background(), sys, "hello", "")
	require.NoError(t, err)
	assert.Equal(t, "got:"+marker, result)
	require.NotEmpty(t, c.systemPromptTempPath)
	_, statErr := os.Stat(c.systemPromptTempPath)
	assert.True(t, os.IsNotExist(statErr), "system prompt temp file must be removed after the call, stat err = %v", statErr)
}

// TestQuery_LargeSystemPromptFileIsRemoved is the streaming sibling: Query
// hands the prompt over as a file and removes it once the stream ends.
func TestQuery_LargeSystemPromptFileIsRemoved(t *testing.T) {
	const marker = "SYSPROMPT-MARKER-ai-04"
	mockPath := writeMockClaude(t, `file=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--system-prompt-file" ]; then file="$2"; fi
  shift
done
if [ -n "$file" ] && grep -q `+marker+` "$file"; then
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"got:`+marker+`"}]}}\n'
else
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"marker-missing"}]}}\n'
fi
`)
	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath

	sys := strings.Repeat("x", digest.StdinThreshold) + marker
	textCh, errCh, sidCh := c.Query(context.Background(), sys, "hello", "")
	var got strings.Builder
	for chunk := range textCh {
		got.WriteString(chunk.Text)
	}
	for err := range errCh {
		require.NoError(t, err)
	}
	for range sidCh {
	}
	assert.Equal(t, "got:"+marker, got.String())
	require.NotEmpty(t, c.systemPromptTempPath)
	_, statErr := os.Stat(c.systemPromptTempPath)
	assert.True(t, os.IsNotExist(statErr), "system prompt temp file must be removed after the stream, stat err = %v", statErr)
}

// TestQuerySync_SystemPromptFileWriteFailureFailsTheCall: when the temp file
// cannot be written the call fails instead of putting the oversized prompt
// back on argv; the CLI is never started.
func TestQuerySync_SystemPromptFileWriteFailureFailsTheCall(t *testing.T) {
	ran := filepath.Join(t.TempDir(), "ran")
	mockPath := writeMockClaude(t, `touch `+ran+`
printf '{"type":"result","result":"ok"}'`)
	c := NewClient("test-model", "", "")
	c.claudeCmd = mockPath
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "missing"))

	_, _, err := c.QuerySync(context.Background(), strings.Repeat("x", digest.StdinThreshold+1), "hello", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "writing system prompt file")
	_, statErr := os.Stat(ran)
	assert.True(t, os.IsNotExist(statErr), "the CLI must not run without its system prompt")
}
