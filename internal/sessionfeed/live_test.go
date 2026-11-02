package sessionfeed

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var liveNow = time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)

func liveFile(t *testing.T, codex bool, lines ...string) Conversation {
	t.Helper()
	path := filepath.Join(t.TempDir(), "main.jsonl")
	require.NoError(t, os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0600))
	return Conversation{Path: path, AgentSessionID: "main", Codex: codex}
}
func liveRec(kind string, p any) string {
	raw, _ := json.Marshal(map[string]any{"timestamp": "2026-11-02T12:00:00Z", "type": kind, "payload": p})
	return string(raw)
}
func TestLiveCompletedActionSurvivesPollingAndNewTurnResets(t *testing.T) {
	c := liveFile(t, false, assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "/repo/file.go"})), userBlocks("u1", toolResult("t1")))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.NotNil(t, live.Latest)
	assert.Equal(t, "t1", live.Latest.ID)
	assert.Nil(t, live.Current)
	again, err := LiveOf(c, false, liveNow.Add(time.Second))
	require.NoError(t, err)
	assert.Equal(t, live.Latest, again.Latest)
	f, err := os.OpenFile(c.Path, os.O_APPEND|os.O_WRONLY, 0600)
	require.NoError(t, err)
	_, err = f.WriteString(`{"type":"user","timestamp":"2026-11-02T12:00:01Z","message":{"content":"next question"}}` + "\n")
	require.NoError(t, err)
	require.NoError(t, f.Close())
	next, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Nil(t, next.Latest)
	assert.Nil(t, next.Current)
}
func TestLiveToolResultDoesNotResetOtherOpenCalls(t *testing.T) {
	c := liveFile(t, false, assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"}), toolUse("t2", "Bash", map[string]any{"command": "go test"})), userBlocks("u1", toolResult("t1")))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.NotNil(t, live.Current)
	assert.Equal(t, "t2", live.Current.ID)
	assert.Equal(t, "t1", live.Latest.ID)
}
func TestLiveClaudeBackgroundSurvivesLaunchResultAndMainEnd(t *testing.T) {
	c := liveFile(t, false, assistantRec("a1", "m1", toolUse("launch", "Agent", map[string]any{"description": "check files"})), userBlocks("u1", toolResult("launch")), `{"type":"assistant","message":{"content":[{"type":"text","text":"waiting"}],"stop_reason":"end_turn"}}`)
	dir := strings.TrimSuffix(c.Path, ".jsonl") + "/subagents"
	require.NoError(t, os.MkdirAll(dir, 0700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "agent-a.meta.json"), []byte(`{"toolUseId":"launch","requestShape":"background","finished":false}`), 0600))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.False(t, live.TurnActive)
	require.Len(t, live.Agents, 1)
	assert.Equal(t, StatusRunning, live.Agents[0].Ref.Status)
	assert.Nil(t, live.Current)
	assert.Nil(t, live.Latest)
}

const liveParent = "11111111-1111-4111-8111-111111111111"
const liveChild = "22222222-2222-4222-8222-222222222222"

func codexLiveFixture(t *testing.T, lines ...string) Conversation {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "sessions", "2026", "11", "02")
	require.NoError(t, os.MkdirAll(dir, 0700))
	path := filepath.Join(dir, "rollout-2026-11-02-"+liveParent+".jsonl")
	require.NoError(t, os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0600))
	return Conversation{Path: path, AgentSessionID: liveParent, Codex: true}
}
func addLiveChild(t *testing.T, c Conversation, parent string) string {
	t.Helper()
	path := filepath.Join(filepath.Dir(c.Path), "rollout-2026-11-02-"+liveChild+".jsonl")
	meta := liveRec("session_meta", map[string]any{"id": liveChild, "source": map[string]any{"subagent": map[string]any{"thread_spawn": map[string]any{"parent_thread_id": parent}}}})
	require.NoError(t, os.WriteFile(path, []byte(meta+"\n"+liveRec("event_msg", map[string]any{"type": "agent_message", "message": "report"})+"\n"), 0600))
	return path
}
func TestLiveCodexLifecycleAndSafeDrillIn(t *testing.T) {
	spawn := liveRec("event_msg", map[string]any{"type": "collab_agent_spawn_end", "new_thread_id": liveChild, "status": "running", "prompt": "check files"})
	c := codexLiveFixture(t, spawn, liveRec("event_msg", map[string]any{"type": "task_complete"}))
	addLiveChild(t, c, liveParent)
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Agents, 1)
	assert.Equal(t, StatusRunning, live.Agents[0].Ref.Status)
	assert.True(t, live.Agents[0].CanOpen)
	res, _, err := FindSubagent([]Conversation{c}, "codex:"+liveChild)
	require.NoError(t, err)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "report", res.Entries[0].Text)
	// A related-looking filename is not authorization: the child must declare this parent.
	addLiveChild(t, c, "33333333-3333-4333-8333-333333333333")
	_, _, err = FindSubagent([]Conversation{c}, "codex:"+liveChild)
	require.Error(t, err)
	_, _, err = FindSubagent([]Conversation{c}, "codex:../../secret")
	require.Error(t, err)
}
func TestLiveCodexPaginatedResumeCloseAndUnknown(t *testing.T) {
	item := func(tool, status string) string {
		return liveRec("event_msg", map[string]any{"type": "item_completed", "item": map[string]any{"type": "CollabAgentToolCall", "tool": tool, "status": "completed", "receiverThreadIds": []string{liveChild}, "agentsStates": map[string]any{liveChild: map[string]any{"status": status}}, "prompt": "inspect"}})
	}
	for _, tc := range []struct{ tool, status, want string }{{"spawnAgent", "running", StatusRunning}, {"resumeAgent", "running", StatusRunning}, {"closeAgent", "shutdown", StatusFinished}, {"spawnAgent", "notFound", StatusUnknown}} {
		t.Run(tc.tool+tc.status, func(t *testing.T) {
			c := codexLiveFixture(t, item("spawnAgent", "running"), item(tc.tool, tc.status))
			live, err := LiveOf(c, false, liveNow)
			require.NoError(t, err)
			require.Len(t, live.Agents, 1)
			assert.Equal(t, tc.want, live.Agents[0].Ref.Status)
		})
	}
}
func TestLiveCodexCompletedToolAndIncompleteTail(t *testing.T) {
	c := codexLiveFixture(t, liveRec("event_msg", map[string]any{"type": "task_started"}), liveRec("response_item", map[string]any{"type": "custom_tool_call", "name": "functions.exec", "call_id": "c1", "input": `await tools.exec_command({cmd:"go test"})`}), liveRec("response_item", map[string]any{"type": "custom_tool_call_output", "call_id": "c1", "output": "ok"}))
	f, err := os.OpenFile(c.Path, os.O_APPEND|os.O_WRONLY, 0600)
	require.NoError(t, err)
	_, err = f.WriteString(liveRec("event_msg", map[string]any{"type": "user_message", "message": "uncommitted"}))
	require.NoError(t, err)
	require.NoError(t, f.Close())
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.NotNil(t, live.Latest)
	assert.Equal(t, "go test", live.Latest.Summary)
	assert.Nil(t, live.Current)
	raw, err := json.Marshal(live)
	require.NoError(t, err)
	assert.Contains(t, string(raw), `"agents":[]`)
}

func TestLiveUnavailableInputsNeverReportZeroAgents(t *testing.T) {
	for _, raw := range []string{"", "{broken}\n", "{\"type\":\"future_record\"}\n", string(zstdMagic) + "compressed\n"} {
		c := liveFile(t, false)
		require.NoError(t, os.WriteFile(c.Path, []byte(raw), 0600))
		live, err := LiveOf(c, false, liveNow)
		require.Error(t, err)
		assert.Nil(t, live)
	}
	c := liveFile(t, true, liveRec("event_msg", map[string]any{"type": "task_started"}))
	raw := strings.Repeat(" ", liveWindow) + "\n" + liveRec("event_msg", map[string]any{"type": "user_message", "message": "question"}) + "\n"
	require.NoError(t, os.WriteFile(c.Path, []byte(raw), 0600))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "unknown", live.AgentsState)
}
func TestLiveCodexChildOwnCompletionAndResumeTimestamp(t *testing.T) {
	c := codexLiveFixture(t, liveRec("event_msg", map[string]any{"type": "collab_agent_spawn_end", "new_thread_id": liveChild, "status": "running"}))
	path := addLiveChild(t, c, liveParent)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	require.NoError(t, err)
	_, err = f.WriteString(liveRec("event_msg", map[string]any{"type": "task_complete"}) + "\n")
	require.NoError(t, err)
	require.NoError(t, f.Close())
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Agents, 1)
	assert.Equal(t, StatusFinished, live.Agents[0].Ref.Status)
	// A symlink to an otherwise valid child is never opened.
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	require.NoError(t, os.Remove(path))
	outside := filepath.Join(t.TempDir(), "child.jsonl")
	require.NoError(t, os.WriteFile(outside, raw, 0600))
	require.NoError(t, os.Symlink(outside, path))
	live, err = LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.False(t, live.Agents[0].CanOpen)
}
