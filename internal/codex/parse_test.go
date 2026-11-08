package codex

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/digest"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

func TestParseJSONLOutput_Success(t *testing.T) {
	jsonl := `{"type":"thread.started","thread_id":"t1"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i1","type":"agent_message","content":"Hello world"}}
{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":50}}
`
	result, usage, err := parseJSONLOutput([]byte(jsonl))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "Hello world" {
		t.Errorf("result = %q, want %q", result, "Hello world")
	}
	if usage.InputTokens != 100 {
		t.Errorf("InputTokens = %d, want 100", usage.InputTokens)
	}
	if usage.OutputTokens != 50 {
		t.Errorf("OutputTokens = %d, want 50", usage.OutputTokens)
	}
}

func TestParseJSONLOutput_LastAgentMessage(t *testing.T) {
	// Multiple agent messages — last one wins.
	jsonl := `{"type":"item.completed","item":{"id":"i1","type":"agent_message","content":"first"}}
{"type":"item.completed","item":{"id":"i2","type":"agent_message","content":"second"}}
{"type":"turn.completed"}
`
	result, _, err := parseJSONLOutput([]byte(jsonl))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "second" {
		t.Errorf("result = %q, want %q", result, "second")
	}
}

func TestParseJSONLOutput_NoAgentMessage(t *testing.T) {
	jsonl := `{"type":"thread.started","thread_id":"t1"}
{"type":"turn.completed"}
`
	_, _, err := parseJSONLOutput([]byte(jsonl))
	if err == nil {
		t.Error("expected error for missing agent_message")
	}
}

func TestParseJSONLOutput_Error(t *testing.T) {
	jsonl := `{"type":"error","error":{"message":"rate limit exceeded","code":"rate_limit"}}
`
	_, _, err := parseJSONLOutput([]byte(jsonl))
	if err == nil {
		t.Error("expected error for codex error event")
	}
}

func TestParseJSONLOutput_IgnoresNonAgentItems(t *testing.T) {
	jsonl := `{"type":"item.completed","item":{"id":"i1","type":"command_execution","content":"ls output"}}
{"type":"item.completed","item":{"id":"i2","type":"agent_message","content":"result"}}
{"type":"turn.completed"}
`
	result, _, err := parseJSONLOutput([]byte(jsonl))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "result" {
		t.Errorf("result = %q, want %q", result, "result")
	}
}

func TestParseJSONLOutput_AccumulatesUsage(t *testing.T) {
	jsonl := `{"type":"turn.completed","usage":{"input_tokens":50,"output_tokens":20}}
{"type":"item.completed","item":{"id":"i1","type":"agent_message","content":"ok"}}
{"type":"turn.completed","usage":{"input_tokens":30,"output_tokens":10}}
`
	_, usage, err := parseJSONLOutput([]byte(jsonl))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if usage.InputTokens != 80 {
		t.Errorf("InputTokens = %d, want 80", usage.InputTokens)
	}
	if usage.OutputTokens != 30 {
		t.Errorf("OutputTokens = %d, want 30", usage.OutputTokens)
	}
}

func TestParseJSONLOutput_EmptyInput(t *testing.T) {
	_, _, err := parseJSONLOutput([]byte(""))
	if err == nil {
		t.Error("expected error for empty input")
	}
}

func TestParseJSONLOutput_InvalidJSON(t *testing.T) {
	// Invalid JSON lines are silently skipped.
	jsonl := `not json
{"type":"item.completed","item":{"id":"i1","type":"agent_message","content":"ok"}}
{"type":"turn.completed"}
`
	result, _, err := parseJSONLOutput([]byte(jsonl))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "ok" {
		t.Errorf("result = %q, want %q", result, "ok")
	}
}

func TestParseJSONLOutput_TextFieldFallback(t *testing.T) {
	// Newer Codex CLI uses "text" instead of "content".
	jsonl := `{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"hello from text"}}
{"type":"turn.completed"}
`
	result, _, err := parseJSONLOutput([]byte(jsonl))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "hello from text" {
		t.Errorf("result = %q, want %q", result, "hello from text")
	}
}

func TestCodexItem_MessageText(t *testing.T) {
	// Text takes precedence over Content.
	item := &CodexItem{Text: "from text", Content: "from content"}
	if got := item.MessageText(); got != "from text" {
		t.Errorf("MessageText() = %q, want %q", got, "from text")
	}

	// Falls back to Content when Text is empty.
	item2 := &CodexItem{Content: "from content"}
	if got := item2.MessageText(); got != "from content" {
		t.Errorf("MessageText() = %q, want %q", got, "from content")
	}
}

// A command/tool item larger than any scanner buffer must not end parsing
// early: the final agent_message after it is the answer, not the preamble.
func TestParseJSONLOutput_OversizedLineDoesNotHideFinalMessage(t *testing.T) {
	big := strings.Repeat("x", 2*1024*1024)
	jsonl := `{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"Let me look that up"}}` + "\n" +
		`{"type":"item.completed","item":{"id":"i1","type":"command_execution","aggregated_output":"` + big + `"}}` + "\n" +
		`{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"final answer"}}` + "\n" +
		`{"type":"turn.completed"}` + "\n"
	result, _, err := parseJSONLOutput([]byte(jsonl))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "final answer" {
		t.Fatalf("result = %q, want the final agent_message", result)
	}
}

// A batch run that exited cleanly without turn.completed is an invalid
// output (or its failed turn), never its last message: a cut-off run must
// not return its preamble as the answer.
func TestParseJSONLOutput_RequiresTurnCompleted(t *testing.T) {
	_, _, err := parseJSONLOutput([]byte(`{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"Let me look that up"}}` + "\n"))
	require.ErrorIs(t, err, errNoTurnCompleted)
	var failure *providers.Failure
	require.ErrorAs(t, err, &failure)
	assert.Equal(t, providers.InvalidOutput, failure.Category)

	_, _, err = parseJSONLOutput([]byte(`{"type":"error","message":"429 Too Many Requests"}` + "\n"))
	require.ErrorIs(t, err, errNoTurnCompleted)
	assert.Contains(t, logredact.Full(err), "429 Too Many Requests")
}

// QuerySync and the generator follow the same rule on a clean exit.
func TestBatchCallsRequireTurnCompleted(t *testing.T) {
	stdout := `{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"preamble"}}`
	_, _, err := NewClient("gpt-x", "", fakeCodexScript(t, stdout, "", 0)).QuerySync(context.Background(), "sys", "hi", "")
	require.ErrorIs(t, err, errNoTurnCompleted)
	_, _, _, err = NewCodexGenerator("gpt-x", "gpt-x", fakeCodexScript(t, stdout, "", 0)).Generate(context.Background(), "sys", "hi", "")
	require.ErrorIs(t, err, errNoTurnCompleted)
}

// A batch run cut off with only stderr to say why keeps that stderr, and is
// not called invalid output: the transport rules still read it.
func TestBatchIncompleteRunKeepsStderr(t *testing.T) {
	stdout := `{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"preamble"}}`
	const why = "stream disconnected before completion: 503 Service Unavailable"
	_, _, qerr := NewClient("gpt-x", "", fakeCodexScript(t, stdout, why, 0)).QuerySync(context.Background(), "sys", "hi", "")
	_, _, _, gerr := NewCodexGenerator("gpt-x", "gpt-x", fakeCodexScript(t, stdout, why, 0)).Generate(context.Background(), "sys", "hi", "")
	_, _, _, werr := digest.WithCallTimeout(NewCodexGenerator("gpt-x", "gpt-x", fakeCodexScript(t, stdout, why, 0)), time.Minute).
		Generate(context.Background(), "sys", "hi", "")
	for _, err := range []error{qerr, gerr, werr} {
		require.ErrorIs(t, err, errNoTurnCompleted)
		assert.Contains(t, logredact.Full(err), why)
		var failure *providers.Failure
		require.ErrorAs(t, err, &failure)
		assert.Equal(t, providers.Transport, failure.Category)
	}
	// The batch wrapper the daemon and the router see marks it an AI call
	// failure (retried, never a strike against the request).
	assert.ErrorIs(t, werr, digest.ErrAICall)
}

// Stderr that says nothing about the transport keeps an incomplete run
// unclassified: neither transport nor invalid output — also when an earlier
// line reports a lost stream codex recovered from (its retry notice).
func TestBatchIncompleteRunOtherStderrStaysUnknown(t *testing.T) {
	stdout := `{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"preamble"}}`
	for _, stderr := range []string{
		"something odd happened",
		"stream disconnected before completion: reset; retrying 1/5\nthread panicked at config.rs",
	} {
		bin := filepath.Join(t.TempDir(), "codex")
		require.NoError(t, os.WriteFile(bin, []byte("#!/bin/sh\ncat > /dev/null\necho '"+stdout+"'\ncat >&2 <<'EOF'\n"+stderr+"\nEOF\n"), 0o755))
		_, _, _, err := NewCodexGenerator("gpt-x", "gpt-x", bin).Generate(context.Background(), "sys", "hi", "")
		require.ErrorIs(t, err, errNoTurnCompleted)
		var failure *providers.Failure
		require.ErrorAs(t, err, &failure)
		assert.Equal(t, providers.Unknown, failure.Category, stderr)
	}
}
