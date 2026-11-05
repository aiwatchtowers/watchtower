package sessionfeed

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// compressInPlace replaces path's content with its zstd frame, the way Codex
// stores an older rollout under the same name.
func compressInPlace(t *testing.T, path string) {
	t.Helper()
	plain, err := os.ReadFile(path)
	require.NoError(t, err)
	enc, err := zstd.NewWriter(nil)
	require.NoError(t, err)
	defer enc.Close()
	require.NoError(t, os.WriteFile(path, enc.EncodeAll(plain, nil), 0o600))
}

func codexRolloutFile(t *testing.T, content []byte) Conversation {
	t.Helper()
	path := filepath.Join(t.TempDir(), "rollout-x.jsonl")
	require.NoError(t, os.WriteFile(path, content, 0o600))
	return Conversation{AgentSessionID: "A", Path: path, Codex: true}
}

func TestFeed01_CompressedRolloutReadLeavesFileUntouched(t *testing.T) {
	c := codexRolloutFile(t, readFixture(t, "mixed.jsonl"))
	compressInPlace(t, c.Path)
	old := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	require.NoError(t, os.Chtimes(c.Path, old, old))
	before, err := os.Stat(c.Path)
	require.NoError(t, err)

	f, err := Build([]Conversation{c}, nil, nil)
	require.NoError(t, err)
	require.Len(t, f.Entries, 6)
	_, err = LiveOf(c, false, liveNow)
	require.NoError(t, err)
	_, err = ActivityOf(c.Path, true, false)
	require.NoError(t, err)

	after, err := os.Stat(c.Path)
	require.NoError(t, err)
	assert.Equal(t, before.Size(), after.Size())
	assert.True(t, before.ModTime().Equal(after.ModTime()), "mtime changed")
	entries, err := os.ReadDir(filepath.Dir(c.Path))
	require.NoError(t, err)
	assert.Len(t, entries, 1, "reader must create no sibling files")
}

func TestParseCodex_CompressedRolloutGivesEntries(t *testing.T) {
	raw := readFixture(t, "mixed.jsonl")
	plain, err := Build([]Conversation{codexRolloutFile(t, raw)}, nil, nil)
	require.NoError(t, err)

	c := codexRolloutFile(t, raw)
	compressInPlace(t, c.Path)
	got, err := Build([]Conversation{c}, nil, nil)
	require.NoError(t, err)
	assert.Equal(t, plain.Entries, got.Entries)
	assert.Empty(t, got.Unknown)
	assert.EqualValues(t, len(raw), got.Cursor.Offset, "the cursor counts decompressed bytes")

	again, err := Build([]Conversation{c}, &got.Cursor, nil)
	require.NoError(t, err)
	assert.Empty(t, again.Entries, "a cursor at the end reads nothing new")
	assert.Equal(t, got.Cursor, again.Cursor)

	// A frame that does not decode stays disclosed, not a failed feed.
	bad := codexRolloutFile(t, append(append([]byte{}, zstdMagic...), "not a frame\n"...))
	res, err := Build([]Conversation{bad}, nil, nil)
	require.NoError(t, err)
	assert.Empty(t, res.Entries)
	assert.Equal(t, 1, res.Unknown["<zstd>"])
}

func TestLiveLine_CompressedRollout(t *testing.T) {
	c := codexLiveFixture(t,
		liveRec("event_msg", map[string]any{"type": "task_started"}),
		liveRec("response_item", map[string]any{"type": "custom_tool_call", "name": "functions.exec", "call_id": "c1", "input": `await tools.exec_command({cmd:"go test"})`}),
	)
	compressInPlace(t, c.Path)
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.NotNil(t, live.Current)
	assert.Equal(t, "go test", live.Current.Summary)
	assert.Equal(t, "known", live.AgentsState)

	activity, err := ActivityOf(c.Path, true, false)
	require.NoError(t, err)
	require.NotNil(t, activity)
	assert.Equal(t, "go test", activity.Summary)
}

func TestFeed_CodexSubagentsListed(t *testing.T) {
	for _, compressed := range []bool{false, true} {
		t.Run(map[bool]string{false: "plain", true: "compressed"}[compressed], func(t *testing.T) {
			c := codexLiveFixture(t,
				liveRec("event_msg", map[string]any{"type": "user_message", "message": "check the files"}),
				liveRec("event_msg", map[string]any{"type": "collab_agent_spawn_end", "new_thread_id": liveChild, "status": "running", "prompt": "check files"}),
			)
			child := addLiveChild(t, c, liveParent)
			if compressed {
				compressInPlace(t, c.Path)
				compressInPlace(t, child)
			}
			feed, err := Build([]Conversation{c}, nil, nil)
			require.NoError(t, err)
			require.Len(t, feed.Entries, 1, "markers join the Subagents list, not the dialog")
			require.Len(t, feed.Subagents, 1)
			m := feed.Subagents[0]
			assert.Equal(t, KindSubagent, m.Kind)
			assert.Equal(t, "codex:"+liveChild, m.ID)
			assert.Equal(t, liveParent, m.Conversation)
			require.NotNil(t, m.Subagent)
			assert.Equal(t, liveChild, m.Subagent.AgentID)
			assert.Equal(t, "check files", m.Subagent.Description)

			// The listed marker opens: its selector resolves to the child.
			res, _, err := FindSubagent([]Conversation{c}, m.Subagent.ToolUseID)
			require.NoError(t, err)
			require.NotNil(t, res)
			require.Len(t, res.Entries, 1)
			assert.Equal(t, "report", res.Entries[0].Text)

			// An earlier conversation behind the cursor still lists its agents.
			later, err := Build([]Conversation{c}, &feed.Cursor, nil)
			require.NoError(t, err)
			assert.Len(t, later.Subagents, 1)
		})
	}
}

func TestFeed_CodexWithoutAgentsListsNone(t *testing.T) {
	feed, err := Build([]Conversation{codexRolloutFile(t, readFixture(t, "mixed.jsonl"))}, nil, nil)
	require.NoError(t, err)
	assert.Empty(t, feed.Subagents)
}

// Codex records an owner line typed while a turn runs as an ordinary
// user_message inside that turn: there is no queued shape, so it reads as a
// plain owner entry (FEED-02 note).
func TestParseCodex_QueuedOwnerLine(t *testing.T) {
	c := codexLiveFixture(t,
		liveRec("event_msg", map[string]any{"type": "task_started"}),
		liveRec("event_msg", map[string]any{"type": "user_message", "message": "first question"}),
		liveRec("response_item", map[string]any{"type": "function_call", "name": "shell", "call_id": "c1", "arguments": `{"command":["ls"]}`}),
		liveRec("event_msg", map[string]any{"type": "user_message", "message": "typed while busy"}),
		liveRec("event_msg", map[string]any{"type": "agent_message", "message": "done"}),
		liveRec("event_msg", map[string]any{"type": "task_complete"}),
	)
	feed, err := Build([]Conversation{c}, nil, nil)
	require.NoError(t, err)
	require.Len(t, feed.Entries, 3)
	assert.Equal(t, []Kind{KindOwner, KindOwner, KindAgent}, []Kind{feed.Entries[0].Kind, feed.Entries[1].Kind, feed.Entries[2].Kind})
	assert.Equal(t, "typed while busy", feed.Entries[1].Text)
}
