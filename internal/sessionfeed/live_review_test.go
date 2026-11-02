package sessionfeed

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func liveRecAt(at time.Time, kind string, payload any) string {
	raw, _ := json.Marshal(map[string]any{"timestamp": at.Format(time.RFC3339Nano), "type": kind, "payload": payload})
	return string(raw)
}
func reviewChild(t *testing.T, c Conversation, id string, records ...string) string {
	t.Helper()
	path := filepath.Join(filepath.Dir(c.Path), "rollout-2026-11-02-"+id+".jsonl")
	meta := liveRec("session_meta", map[string]any{"id": id, "parent_thread_id": c.AgentSessionID})
	require.NoError(t, os.WriteFile(path, []byte(meta+"\n"+strings.Join(records, "\n")+"\n"), 0600))
	return path
}
func reviewSpawn(at time.Time, id string) string {
	return liveRecAt(at, "event_msg", map[string]any{"type": "collab_agent_spawn_end", "new_thread_id": id, "status": "running"})
}
func TestLiveReviewParentTerminalAndResumeAreMonotonic(t *testing.T) {
	t0, t1, t2 := liveNow, liveNow.Add(time.Second), liveNow.Add(2*time.Second)
	for _, tc := range []struct {
		name, parentEvent, parentStatus, childEvent string
		parentAt, childAt                           time.Time
		want                                        string
	}{
		{"newer close", "collab_close_end", "shutdown", "task_started", t2, t1, StatusFinished},
		{"equal close", "collab_close_end", "shutdown", "task_started", t2, t2, StatusFinished},
		{"newer resume", "collab_resume_end", "running", "task_complete", t2, t1, StatusRunning},
		{"equal resume", "collab_resume_end", "running", "task_complete", t2, t2, StatusRunning},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := codexLiveFixture(t, reviewSpawn(t0, liveChild), liveRecAt(tc.parentAt, "event_msg", map[string]any{"type": tc.parentEvent, "receiver_thread_id": liveChild, "status": tc.parentStatus}))
			reviewChild(t, c, liveChild, liveRecAt(tc.childAt, "event_msg", map[string]any{"type": tc.childEvent}))
			live, err := LiveOf(c, false, t2)
			require.NoError(t, err)
			require.Len(t, live.Agents, 1)
			assert.Equal(t, tc.want, live.Agents[0].Ref.Status)
		})
	}
}
func TestLiveReviewHealthyDirectSiblingIgnoresUnhealthyEarlierBranch(t *testing.T) {
	bad, good := liveChild, "33333333-3333-4333-8333-333333333333"
	c := codexLiveFixture(t, reviewSpawn(liveNow, bad), reviewSpawn(liveNow, good))
	reviewChild(t, c, bad) // Metadata only: no supported live records yet.
	path := reviewChild(t, c, good, liveRec("event_msg", map[string]any{"type": "agent_message", "message": "healthy report"}))
	res, got, err := FindSubagent([]Conversation{c}, "codex:"+good)
	require.NoError(t, err)
	assert.Equal(t, path, got)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "healthy report", res.Entries[0].Text)
	_, _, err = FindSubagent([]Conversation{c}, "codex:"+bad)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no supported activity records", "selected-target errors must not be swallowed")
}
func TestLiveReviewUnreadableClaudeMetadataIsUnknownNotEmpty(t *testing.T) {
	c := liveFile(t, false, assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"})))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "known", live.AgentsState)
	assert.Empty(t, live.Agents)
	if os.Geteuid() == 0 {
		t.Skip("root bypasses directory read permissions")
	}
	dir := filepath.Join(strings.TrimSuffix(c.Path, ".jsonl"), "subagents")
	require.NoError(t, os.MkdirAll(dir, 0700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "agent-hidden.meta.json"), []byte(`{"toolUseId":"hidden","finished":false}`), 0600))
	require.NoError(t, os.Chmod(dir, 0))
	t.Cleanup(func() { _ = os.Chmod(dir, 0700) })
	live, err = LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "unknown", live.AgentsState)
	require.NotNil(t, live.Current)
	assert.Equal(t, "t1", live.Current.ID)
}
func TestLiveReviewImageOnlyTurnResetsAndMixedResultsDoNot(t *testing.T) {
	initial := assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"}), toolUse("t2", "Read", map[string]any{"file_path": "b.go"}))
	image := map[string]any{"type": "image", "source": map[string]any{"type": "base64", "data": "fixture"}}
	c := liveFile(t, false, initial, userBlocks("result", toolResult("t1")), userBlocks("image", image))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Nil(t, live.Current)
	assert.Nil(t, live.Latest)
	assert.False(t, live.TurnAt.IsZero())
	c = liveFile(t, false, initial, userBlocks("mixed", image, toolResult("t1")))
	live, err = LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.NotNil(t, live.Current)
	assert.Equal(t, "t2", live.Current.ID)
	require.NotNil(t, live.Latest)
	assert.Equal(t, "t1", live.Latest.ID)
}
func TestLiveReviewReconcileBeforeVisibleCapAndBoundCandidateReads(t *testing.T) {
	for _, count := range []int{33, maxLiveAgentCandidates + 3} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			lines := make([]string, 0, count)
			ids := make([]string, 0, count)
			for i := range count {
				id := fmt.Sprintf("%08x-2222-4222-8222-%012x", i, i)
				ids = append(ids, id)
				lines = append(lines, reviewSpawn(liveNow.Add(time.Duration(i)*time.Second), id))
			}
			c := codexLiveFixture(t, lines...)
			for i, id := range ids {
				event := "task_complete"
				if i == count-1 {
					event = "task_started"
				}
				reviewChild(t, c, id, liveRecAt(liveNow.Add(time.Duration(count+1)*time.Second), "event_msg", map[string]any{"type": event}))
			}
			live, err := LiveOf(c, false, liveNow.Add(time.Hour))
			require.NoError(t, err)
			assert.LessOrEqual(t, live.inspectedAgents, maxLiveAgentCandidates)
			running := []LiveAgent{}
			for _, a := range live.Agents {
				if a.Ref.Status == StatusRunning {
					running = append(running, a)
				}
			}
			require.Len(t, running, 1)
			assert.Equal(t, ids[count-1], running[0].Ref.AgentID)
			assert.Zero(t, live.AgentsMore, "uninspected old spawn state is not a definite running count")
			if count > maxLiveAgentCandidates {
				assert.Equal(t, "unknown", live.AgentsState)
				assert.Equal(t, maxLiveAgentCandidates, live.inspectedAgents)
			}
		})
	}
}

func TestLiveReviewWatchtowerTypedTurnsResetButNoticesDoNot(t *testing.T) {
	initial := assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"}), toolUse("t2", "Read", map[string]any{"file_path": "b.go"}))
	for _, prompt := range []string{"Review round #12 sent (1 comment)", "From a Watchtower code question: check the parser"} {
		c := liveFile(t, false, initial, userBlocks("result", toolResult("t1")), userStr("review", prompt))
		live, err := LiveOf(c, false, liveNow)
		require.NoError(t, err)
		assert.Nil(t, live.Current)
		assert.Nil(t, live.Latest)
		assert.False(t, live.TurnAt.IsZero())
	}
	notice := "<task-notification><task-id>a</task-id><summary>done</summary></task-notification>"
	c := liveFile(t, false, initial, userBlocks("result", toolResult("t1")), userStr("notice", notice), metaUser("meta", "Review round #12 sent"))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.NotNil(t, live.Current)
	require.NotNil(t, live.Latest)
	assert.Equal(t, "t2", live.Current.ID)
	assert.Equal(t, "t1", live.Latest.ID)
}
