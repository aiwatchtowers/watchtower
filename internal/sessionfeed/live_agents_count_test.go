package sessionfeed

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A long Claude session: the launch of a still-running agent lies before the
// live window, and many finished agents have metadata. The count stays known.
func writeLongClaudeSession(t *testing.T, finished int) Conversation {
	return writeLongClaudeSessionWith(t, finished, 0)
}

// extra adds that many more unfinished agents launched before the window.
func writeLongClaudeSessionWith(t *testing.T, finished, extra int) Conversation {
	t.Helper()
	early := assistantRec("a0", "m0", toolUse("early", "Agent", map[string]any{"description": "early review"}))
	late := assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"}))
	raw := early + "\n" + strings.Repeat(" ", liveWindow) + "\n" + late + "\n"
	path := filepath.Join(t.TempDir(), "main.jsonl")
	require.NoError(t, os.WriteFile(path, []byte(raw), 0600))
	dir := filepath.Join(strings.TrimSuffix(path, ".jsonl"), "subagents")
	require.NoError(t, os.MkdirAll(dir, 0700))
	meta := func(name, body string) {
		require.NoError(t, os.WriteFile(filepath.Join(dir, "agent-"+name+".meta.json"), []byte(body), 0600))
	}
	meta("early", `{"toolUseId":"early","requestShape":"background","agentType":"reviewer","description":"early review","finished":false}`)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "agent-early.jsonl"), []byte("{}\n"), 0600))
	for i := range extra {
		name := fmt.Sprintf("run%03d", i)
		meta(name, fmt.Sprintf(`{"toolUseId":"run-%d","requestShape":"foreground","finished":false}`, i))
		require.NoError(t, os.WriteFile(filepath.Join(dir, "agent-"+name+".jsonl"), []byte("{}\n"), 0600))
	}
	for i := range finished {
		meta(fmt.Sprintf("done%03d", i), fmt.Sprintf(`{"toolUseId":"done-%d","requestShape":"background","finished":true}`, i))
	}
	return Conversation{Path: path, AgentSessionID: "main"}
}

func runningAgents(live *Live) []LiveAgent {
	var out []LiveAgent
	for _, a := range live.Agents {
		if a.Ref.Status == StatusRunning {
			out = append(out, a)
		}
	}
	return out
}

func TestLiveClaudeCountKnownPastTheWindow(t *testing.T) {
	live, err := LiveOf(writeLongClaudeSession(t, 3), false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "known", live.AgentsState)
	running := runningAgents(live)
	require.Len(t, running, 1)
	assert.Equal(t, "early", running[0].Ref.ToolUseID)
}

func TestLiveClaudeCountKnownWithManyFinishedAgents(t *testing.T) {
	live, err := LiveOf(writeLongClaudeSession(t, maxLiveAgentCandidates+20), false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "known", live.AgentsState)
	require.Len(t, runningAgents(live), 1)
	assert.Zero(t, live.AgentsMore)
}

func TestLiveClaudeMetadataPastBudgetIsUnknown(t *testing.T) {
	live, err := LiveOf(writeLongClaudeSession(t, maxLiveMetas), false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "unknown", live.AgentsState)
}

func TestLiveClaudeRefusedLaunchIsNotWorking(t *testing.T) {
	refused := map[string]any{"type": "tool_result", "tool_use_id": "bad", "content": "Agent type 'x' not found", "is_error": true}
	c := liveFile(t, false,
		assistantRec("a1", "m1", toolUse("bad", "Agent", map[string]any{"description": "missing type"})),
		userBlocks("u1", refused),
		assistantRec("a2", "m2", toolUse("t1", "Read", map[string]any{"file_path": "a.go"})))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "known", live.AgentsState)
	assert.Empty(t, runningAgents(live))
}

// A sidechain sees its own launches only in the window, so a cut stays unknown.
func TestLiveClaudeSidechainCutStaysUnknown(t *testing.T) {
	c := writeLongClaudeSession(t, 0)
	live, err := LiveOf(c, true, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "unknown", live.AgentsState)
}

// An agent killed with its process never gets "finished" in its sidecar; a
// launch outside the window whose transcript went silent is not counted.
func TestLiveClaudeSilentUnfinishedAgentOutsideWindowIsNotWorking(t *testing.T) {
	c := writeLongClaudeSession(t, 0)
	old := liveNow.Add(-liveMetaStale - time.Minute)
	require.NoError(t, os.Chtimes(filepath.Join(strings.TrimSuffix(c.Path, ".jsonl"), "subagents", "agent-early.jsonl"), old, old))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "known", live.AgentsState)
	assert.Empty(t, runningAgents(live))
}

func TestLiveClaudeCutWithoutSidecarsIsUnknown(t *testing.T) {
	c := writeLongClaudeSession(t, 0)
	require.NoError(t, os.RemoveAll(filepath.Join(strings.TrimSuffix(c.Path, ".jsonl"), "subagents")))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "unknown", live.AgentsState)
}

func TestLiveClaudeSidecarWinsOverErrorResult(t *testing.T) {
	failed := map[string]any{"type": "tool_result", "tool_use_id": "launch", "content": "boom", "is_error": true}
	c := liveFile(t, false,
		assistantRec("a1", "m1", toolUse("launch", "Agent", map[string]any{"description": "bg"})),
		userBlocks("u1", failed))
	dir := strings.TrimSuffix(c.Path, ".jsonl") + "/subagents"
	require.NoError(t, os.MkdirAll(dir, 0700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "agent-a.meta.json"), []byte(`{"toolUseId":"launch","finished":false}`), 0600))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.Len(t, runningAgents(live), 1)
}

// More unfinished agents than the inspection budget: the count is not known.
func TestLiveClaudeTooManyWorkingCandidatesIsUnknown(t *testing.T) {
	live, err := LiveOf(writeLongClaudeSessionWith(t, 0, maxLiveAgentCandidates), false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, "unknown", live.AgentsState)
}
