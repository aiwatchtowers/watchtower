package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Transcript lines in Claude Code's JSONL shape, cut to what the hooks read.
func transcriptPrompt(text string) string {
	return `{"type":"user","message":{"role":"user","content":"` + text + `"}}` + "\n"
}

func transcriptToolUse(id string) string {
	return `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"},` +
		`{"type":"tool_use","id":"` + id + `","name":"Bash","input":{"command":"ls"}}]}}` + "\n"
}

func transcriptToolResult(id string) string {
	return `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"` + id + `","content":"a.txt"}]}}` + "\n"
}

func transcriptReply(text string) string {
	return `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"` + text + `"}]}}` + "\n"
}

// transcriptAttachment quotes a call's id the way a hook's attachment entry
// can, after the call itself.
func transcriptAttachment(id string) string {
	return `{"type":"attachment","attachment":{"type":"async_hook_response","toolUseID":"` + id + `"}}` + "\n"
}

func writeTranscript(t *testing.T, lines ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	require.NoError(t, os.WriteFile(path, []byte(strings.Join(lines, "")), 0o600))
	return path
}

func appendTranscript(t *testing.T, path string, lines ...string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	require.NoError(t, err)
	_, err = f.WriteString(strings.Join(lines, ""))
	require.NoError(t, err)
	require.NoError(t, f.Close())
}

func TestToolCallTurn(t *testing.T) {
	path := writeTranscript(t, transcriptPrompt("go"), transcriptToolUse("toolu_A"), transcriptToolResult("toolu_A"),
		transcriptReply("done"))
	end, ok := transcriptSize(path)
	require.True(t, ok)
	appendTranscript(t, path, transcriptAttachment("toolu_A"), transcriptToolUse("toolu_B"), transcriptToolResult("toolu_B"),
		transcriptAttachment("toolu_C"))

	for _, tc := range []struct {
		name     string
		path, id string
		end      int64
		want     toolCallPlace
	}{
		{"the ended turn's call (an attachment after the stop quotes it)", path, "toolu_A", end, toolCallBeforeStop},
		{"a later turn's call", path, "toolu_B", end, toolCallAfterStop},
		{"a call only an attachment quotes", path, "toolu_C", end, toolCallUnknown},
		{"a call not in the transcript", path, "toolu_Z", end, toolCallUnknown},
		{"no tool_use_id", path, "", end, toolCallUnknown},
		{"no transcript path", "", "toolu_A", end, toolCallUnknown},
		{"a missing transcript", filepath.Join(t.TempDir(), "gone.jsonl"), "toolu_A", end, toolCallUnknown},
		{"a transcript shorter than the turn end", path, "toolu_A", end + 1<<20, toolCallUnknown},
		{"a negative turn end", path, "toolu_A", -1, toolCallUnknown},
	} {
		assert.Equal(t, tc.want, toolCallTurn(tc.path, tc.id, tc.end), tc.name)
	}
}

// The scan is bounded on both sides of the turn end; a call past either
// bound is unknown, and a span opened mid-line never reads that line's tail
// as an entry.
func TestToolCallTurn_BoundedSpan(t *testing.T) {
	head, early := transcriptPrompt("go"), transcriptToolUse("toolu_EARLY")
	path := writeTranscript(t, head, early, transcriptToolUse("toolu_A"))
	end, _ := transcriptSize(path)
	appendTranscript(t, path, transcriptToolUse("toolu_B"), transcriptToolUse("toolu_FAR"))

	origBack, origAhead := transcriptLookback, transcriptLookahead
	t.Cleanup(func() { transcriptLookback, transcriptLookahead = origBack, origAhead })
	// The span starts inside the EARLY line and stops inside the FAR one.
	transcriptLookback = end - int64(len(head)) - 10
	transcriptLookahead = int64(len(transcriptToolUse("toolu_B"))) + 10

	assert.Equal(t, toolCallUnknown, toolCallTurn(path, "toolu_EARLY", end), "a line the span opens inside")
	assert.Equal(t, toolCallBeforeStop, toolCallTurn(path, "toolu_A", end))
	assert.Equal(t, toolCallAfterStop, toolCallTurn(path, "toolu_B", end))
	assert.Equal(t, toolCallUnknown, toolCallTurn(path, "toolu_FAR", end), "a line the span cuts off")

	transcriptLookback = end - int64(len(head))
	assert.Equal(t, toolCallBeforeStop, toolCallTurn(path, "toolu_EARLY", end), "a span opened on a line's first byte")
}

// The forward read decides a later turn's call, and a tool_result after the
// turn end whose tool_use sits before it is the ended turn's.
func TestToolCallTurn_ResultAfterTheStop(t *testing.T) {
	path := writeTranscript(t, transcriptToolUse("toolu_A"))
	end, _ := transcriptSize(path)
	appendTranscript(t, path, transcriptToolResult("toolu_A"), transcriptToolUse("toolu_B"))

	assert.Equal(t, toolCallBeforeStop, toolCallTurn(path, "toolu_A", end))
	assert.Equal(t, toolCallAfterStop, toolCallTurn(path, "toolu_B", end))
}

func TestTranscriptSize(t *testing.T) {
	path := writeTranscript(t, transcriptPrompt("go"))
	size, ok := transcriptSize(path)
	assert.True(t, ok)
	assert.Equal(t, int64(len(transcriptPrompt("go"))), size)

	for _, p := range []string{"", filepath.Join(t.TempDir(), "gone.jsonl"), t.TempDir()} {
		_, ok := transcriptSize(p)
		assert.False(t, ok, "%q", p)
	}
}
