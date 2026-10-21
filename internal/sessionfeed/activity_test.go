package sessionfeed

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func toolUse(id, name string, input map[string]any) map[string]any {
	return map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}
}

func toolResult(id string) map[string]any {
	return map[string]any{"type": "tool_result", "tool_use_id": id, "content": "ok"}
}

func writeActivity(t *testing.T, lines ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "t.jsonl")
	require.NoError(t, os.WriteFile(p, []byte(strings.Join(lines, "")), 0o600))
	return p
}

func activityOf(t *testing.T, lines ...string) *Activity {
	t.Helper()
	a, err := ActivityOf(writeActivity(t, lines...), false, false)
	require.NoError(t, err)
	return a
}

func TestActivity_OpenBash(t *testing.T) {
	a := activityOf(t, assistantRec("a1", "m1", toolUse("t1", "Bash", map[string]any{"command": "go test ./internal/db\n-v", "description": ""})))
	require.NotNil(t, a)
	assert.Equal(t, "Bash", a.Tool)
	assert.Equal(t, "go test ./internal/db", a.Summary)
	assert.Equal(t, 0, a.More)
	assert.Equal(t, time.Date(2026, 10, 1, 10, 0, 1, 0, time.UTC), a.StartedAt)
}

func TestActivity_BashDescriptionWins(t *testing.T) {
	a := activityOf(t, assistantRec("a1", "m1", toolUse("t1", "Bash", map[string]any{"command": "go test", "description": "Run db tests"})))
	require.NotNil(t, a)
	assert.Equal(t, "Run db tests", a.Summary)
}

func TestActivity_ClosedIsNil(t *testing.T) {
	assert.Nil(t, activityOf(t,
		assistantRec("a1", "m1", toolUse("t1", "Bash", map[string]any{"command": "ls"})),
		userBlocks("u1", toolResult("t1"))))
}

func TestActivity_ThreeReads(t *testing.T) {
	a := activityOf(t, assistantRec("a1", "m1",
		toolUse("t1", "Read", map[string]any{"file_path": "/a/one.go"}),
		toolUse("t2", "Read", map[string]any{"file_path": "/a/two.go"}),
		toolUse("t3", "Read", map[string]any{"file_path": "/a/three.go"})))
	require.NotNil(t, a)
	assert.Equal(t, "Read", a.Tool)
	assert.Equal(t, "3 files", a.Summary)
	assert.Equal(t, 0, a.More)
}

func TestActivity_SingleReadIsItsFile(t *testing.T) {
	a := activityOf(t, assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "/a/one.go"})))
	require.NotNil(t, a)
	assert.Equal(t, "one.go", a.Summary)
}

func TestActivity_NewestOfMixed(t *testing.T) {
	a := activityOf(t,
		assistantRec("a1", "m1", toolUse("t1", "Bash", map[string]any{"command": "ls"})),
		assistantRec("a2", "m2", toolUse("t2", "Edit", map[string]any{"file_path": "/a/b/WorkchatModel.swift"})))
	require.NotNil(t, a)
	assert.Equal(t, "Edit", a.Tool)
	assert.Equal(t, "WorkchatModel.swift", a.Summary)
	assert.Equal(t, 1, a.More)
}

func TestActivity_AgentAndMCP(t *testing.T) {
	a := activityOf(t, assistantRec("a1", "m1", toolUse("t1", "Agent", map[string]any{"description": "look around"})))
	require.NotNil(t, a)
	assert.Equal(t, "look around", a.Summary)
	a = activityOf(t, assistantRec("a1", "m1", toolUse("t1", "mcp__watchtower-workbench__ask_owner", map[string]any{})))
	require.NotNil(t, a)
	assert.Equal(t, "mcp__watchtower-workbench__ask_owner", a.Tool)
	assert.Equal(t, "ask_owner · watchtower-workbench", a.Summary)
}

func TestActivity_OtherTools(t *testing.T) {
	cases := map[string]struct {
		input map[string]any
		want  string
	}{
		"Grep":      {map[string]any{"pattern": "TODO"}, "TODO"},
		"WebFetch":  {map[string]any{"url": "https://example.com/a/b"}, "example.com"},
		"WebSearch": {map[string]any{"query": "swift tasks"}, "swift tasks"},
		"TodoWrite": {map[string]any{}, "TodoWrite"},
	}
	for name, c := range cases {
		a := activityOf(t, assistantRec("a1", "m1", toolUse("t1", name, c.input)))
		require.NotNil(t, a, name)
		assert.Equal(t, c.want, a.Summary, name)
	}
}

func TestActivity_SidechainIgnored(t *testing.T) {
	rec := assistantRec("a1", "m1", toolUse("t1", "Bash", map[string]any{"command": "ls"}))
	side := rec[:len(rec)-2] + `,"isSidechain":true}` + "\n"
	assert.Nil(t, activityOf(t, side))
	a, err := ActivityOf(writeActivity(t, side), false, true)
	require.NoError(t, err)
	require.NotNil(t, a)
	assert.Equal(t, "Bash", a.Tool)
}

func TestActivity_Clipped(t *testing.T) {
	a := activityOf(t, assistantRec("a1", "m1", toolUse("t1", "Bash", map[string]any{"command": strings.Repeat("é", 300)})))
	require.NotNil(t, a)
	assert.Equal(t, 120, len([]rune(a.Summary)))
	assert.True(t, strings.HasSuffix(a.Summary, "…"))
}

func TestActivity_WindowSkipsPartialLine(t *testing.T) {
	filler := userStr("u", strings.Repeat("x", 1000))
	n := activityWindow/len(filler) + 5
	lines := []string{assistantRec("a0", "m0", toolUse("old", "Bash", map[string]any{"command": "stale"}))}
	for range n {
		lines = append(lines, filler)
	}
	lines = append(lines, assistantRec("a1", "m1", toolUse("t1", "Bash", map[string]any{"command": "fresh"})))
	a := activityOf(t, lines...)
	require.NotNil(t, a)
	assert.Equal(t, "fresh", a.Summary)
	assert.Equal(t, 0, a.More, "the call before the window is not seen")
}

func TestActivity_MissingFile(t *testing.T) {
	_, err := ActivityOf(filepath.Join(t.TempDir(), "none.jsonl"), false, false)
	assert.Error(t, err)
}

func TestActivity_CodexOpenCall(t *testing.T) {
	a, err := ActivityOf(filepath.Join("testdata", "codex", "open_call.jsonl"), true, false)
	require.NoError(t, err)
	require.NotNil(t, a)
	// the newest open call is the custom tool call; the function_call is the other open one
	assert.Equal(t, "exec", a.Tool)
	assert.Equal(t, "ls -la", a.Summary)
	assert.Equal(t, 1, a.More)
	assert.Equal(t, time.Date(2026, 10, 12, 12, 0, 4, 0, time.UTC), a.StartedAt)
}

func TestActivity_CodexCustomToolCall(t *testing.T) {
	call := `{"timestamp":"2026-10-12T12:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call_9","name":"exec","input":"const r = await tools.exec_command({cmd:\"git diff --stat\\nmore\", workdir:\"/x\"});"}}` + "\n"
	out := `{"timestamp":"2026-10-12T12:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_9","output":"ok"}}` + "\n"
	p := writeActivity(t, call)
	a, err := ActivityOf(p, true, false)
	require.NoError(t, err)
	require.NotNil(t, a)
	assert.Equal(t, "exec", a.Tool)
	assert.Equal(t, "git diff --stat", a.Summary)
	p = writeActivity(t, call, out)
	a, err = ActivityOf(p, true, false)
	require.NoError(t, err)
	assert.Nil(t, a)
	p = writeActivity(t, strings.Replace(call, "cmd:", "other:", 1))
	a, err = ActivityOf(p, true, false)
	require.NoError(t, err)
	require.NotNil(t, a)
	assert.Equal(t, "exec", a.Summary)
}
