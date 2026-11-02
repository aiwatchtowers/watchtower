package sessionfeed

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLiveClaudeSidechainUsesSharedDirectoryAndOnlyItsOwnChildren(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "subagents")
	require.NoError(t, os.MkdirAll(dir, 0700))
	pathA := filepath.Join(dir, "agent-a.jsonl")
	require.NoError(t, os.WriteFile(pathA, []byte(assistantRec("a1", "m1", toolUse("call-b", "Agent", map[string]any{"description": "check parser"}))), 0600))
	pathB := filepath.Join(dir, "agent-b.jsonl")
	require.NoError(t, os.WriteFile(pathB, []byte(assistantRec("b1", "mb", toolUse("read-b", "Read", map[string]any{"file_path": "parser.go"}))), 0600))
	for _, entry := range []struct{ name, raw string }{
		{"a", `{"toolUseId":"call-a","description":"self","finished":false}`},
		{"b", `{"toolUseId":"call-b","description":"check parser","finished":false}`},
		{"c", `{"toolUseId":"call-c","description":"peer","finished":false}`},
	} {
		require.NoError(t, os.WriteFile(filepath.Join(dir, "agent-"+entry.name+".meta.json"), []byte(entry.raw), 0600))
	}
	c := Conversation{Path: pathA, AgentSessionID: "a"}
	live, err := LiveOf(c, true, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Agents, 1)
	child := live.Agents[0]
	assert.Equal(t, "call-b", child.Ref.ToolUseID)
	assert.Equal(t, "b", child.Ref.AgentID)
	assert.Equal(t, StatusRunning, child.Ref.Status)
	assert.True(t, child.CanOpen)
	require.NotNil(t, child.Action)
	assert.Equal(t, "parser.go", child.Action.Summary)
	metaB := filepath.Join(dir, "agent-b.meta.json")
	require.NoError(t, os.WriteFile(metaB, []byte(`{"toolUseId":"call-b","finished":true}`), 0600))
	live, err = LiveOf(c, true, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Agents, 1)
	assert.Equal(t, StatusFinished, live.Agents[0].Ref.Status)
	require.NoError(t, os.Remove(metaB))
	live, err = LiveOf(c, true, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Agents, 1)
	assert.Equal(t, StatusUnknown, live.Agents[0].Ref.Status)
	assert.False(t, live.Agents[0].CanOpen)
	assert.Equal(t, "unknown", live.AgentsState)
	require.NoError(t, os.WriteFile(metaB, []byte(`{"toolUseId":"call-b","finished":false}`), 0600))
	require.NoError(t, os.Remove(pathB))
	require.NoError(t, os.Symlink(pathA, pathB))
	live, err = LiveOf(c, true, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Agents, 1)
	assert.False(t, live.Agents[0].CanOpen)
	if os.Geteuid() != 0 {
		require.NoError(t, os.Chmod(dir, 0111))
		t.Cleanup(func() { _ = os.Chmod(dir, 0700) })
		live, err = LiveOf(c, true, liveNow)
		require.NoError(t, err)
		require.Len(t, live.Agents, 1)
		assert.Equal(t, "unknown", live.AgentsState)
		assert.Equal(t, StatusUnknown, live.Agents[0].Ref.Status)
	}
}
