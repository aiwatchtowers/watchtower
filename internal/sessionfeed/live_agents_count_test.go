package sessionfeed

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A long Claude session: the launch of a still-running agent lies before the
// live window, and many finished agents have metadata. The count stays known.
func writeLongClaudeSession(t *testing.T, finished int) Conversation {
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
