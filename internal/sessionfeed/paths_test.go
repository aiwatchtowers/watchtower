package sessionfeed

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// codexChildFixture is a parent rollout that spawned liveChild, plus the
// child's rollout declaring that parent.
func codexChildFixture(t *testing.T) (parent Conversation, child string) {
	t.Helper()
	spawn := liveRec("event_msg", map[string]any{"type": "collab_agent_spawn_end", "new_thread_id": liveChild, "status": "running", "prompt": "check files"})
	parent = codexLiveFixture(t, spawn, liveRec("event_msg", map[string]any{"type": "task_started"}))
	return parent, addLiveChild(t, parent, liveParent)
}

func TestPaths_CodexChildRolloutListed(t *testing.T) {
	c, child := codexChildFixture(t)
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, []string{c.Path, child}, live.Paths())

	f, err := Build([]Conversation{c}, nil, nil)
	require.NoError(t, err)
	assert.Equal(t, []string{c.Path, child}, f.Paths)
}

// An earlier conversation before the cursor is not parsed, but its live
// agents still feed the subagents list: its rollout and child are read.
func TestPaths_CodexEarlierConversationChildListed(t *testing.T) {
	c1, child := codexChildFixture(t)
	const id2 = "44444444-4444-4444-8444-444444444444"
	p2 := filepath.Join(filepath.Dir(c1.Path), "rollout-2026-11-02-"+id2+".jsonl")
	require.NoError(t, os.WriteFile(p2, []byte(liveRec("event_msg", map[string]any{"type": "user_message", "message": "next"})+"\n"), 0600))
	c2 := Conversation{Path: p2, AgentSessionID: id2, Codex: true}
	full, err := Build([]Conversation{c1, c2}, nil, nil)
	require.NoError(t, err)
	f, err := Build([]Conversation{c1, c2}, &full.Cursor, nil)
	require.NoError(t, err)
	assert.Contains(t, f.Paths, c1.Path)
	assert.Contains(t, f.Paths, child)
	assert.Contains(t, f.Paths, p2)
}

func TestPaths_CodexDrillInListsChildRollout(t *testing.T) {
	c, child := codexChildFixture(t)
	res, path, reads, err := FindSubagentReads([]Conversation{c}, "codex:"+liveChild)
	require.NoError(t, err)
	require.NotNil(t, res)
	assert.Equal(t, child, path)
	assert.Contains(t, reads, child)
	assert.Contains(t, reads, c.Path)
}

// Claude markers of an earlier conversation come from its sidecars: after
// a /clear the first conversation's subagents directory and meta files
// are still read, so they are listed, as is a sidecar of the current one
// even when the live snapshot is not read.
func TestPaths_ClaudeEarlierConversationSidecarsListed(t *testing.T) {
	dir := t.TempDir()
	a := writeConv(t, dir, "A", userStr("u1", "one"))
	b := writeConv(t, dir, "B", userStr("u2", "two"))
	subA := filepath.Join(dir, "A", "subagents")
	require.NoError(t, os.MkdirAll(subA, 0o700))
	metaA := filepath.Join(subA, "agent-aa.meta.json")
	require.NoError(t, os.WriteFile(metaA, []byte(`{"toolUseId":"toolu_1","finished":false}`), 0o600))
	full, err := Build([]Conversation{a, b}, nil, nil)
	require.NoError(t, err)
	assert.Equal(t, []string{a.Path, subA, metaA, b.Path}, full.Paths)
	f, err := Build([]Conversation{a, b}, &full.Cursor, nil)
	require.NoError(t, err)
	assert.Equal(t, []string{subA, metaA, b.Path}, f.Paths)
}

func TestPaths_LiveListsMetaSidecars(t *testing.T) {
	root := t.TempDir()
	conv := filepath.Join(root, "s.jsonl")
	require.NoError(t, os.WriteFile(conv, []byte(assistantRec("m1", "m1", textB("hi"))), 0o600))
	dir := filepath.Join(root, "s", "subagents")
	require.NoError(t, os.MkdirAll(dir, 0o700))
	meta := filepath.Join(dir, "agent-a.meta.json")
	require.NoError(t, os.WriteFile(meta, []byte(`{"toolUseId":"call-a","finished":true}`), 0o600))
	live, err := LiveOf(Conversation{Path: conv, AgentSessionID: "s"}, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, []string{conv, dir, meta}, live.Paths())
}

// A candidate rollout whose first line is still being written is rejected
// but listed: once the line completes it may be the child, and only a watch
// on the file sees that.
func TestPaths_CodexIncompleteCandidateListed(t *testing.T) {
	spawn := liveRec("event_msg", map[string]any{"type": "collab_agent_spawn_end", "new_thread_id": liveChild, "status": "running", "prompt": "check files"})
	c := codexLiveFixture(t, spawn, liveRec("event_msg", map[string]any{"type": "task_started"}))
	partial := filepath.Join(filepath.Dir(c.Path), "rollout-2026-11-02-"+liveChild+".jsonl")
	require.NoError(t, os.WriteFile(partial, []byte(`{"timestamp":"2026-11-02T12:00:00Z","type":"session_meta"`), 0600))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Agents, 1)
	assert.False(t, live.Agents[0].CanOpen, "an incomplete first line is not a child yet")
	assert.Equal(t, []string{c.Path, partial}, live.Paths())

	_, _, reads, err := FindSubagentReads([]Conversation{c}, "codex:"+liveChild)
	require.Error(t, err)
	assert.Contains(t, reads, partial)
}
