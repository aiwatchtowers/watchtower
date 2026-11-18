package chatstore

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// The Go homes of the Mac turn store's LIVE-01 guards (the Swift
// LiveSlack01GuardTests that ran ChatTurnStore, gone with it in unified chat
// T8): the engine's store marks a conversation when a Slack connector step
// starts and again in finalize, keeps the first mark, and marks nothing
// without a Slack step (BEHAVIOR LIVE-01 — see docs/inventory/chat.md).

func liveMark(t *testing.T, d *db.DB, conv int64) sql.NullInt64 {
	t.Helper()
	var mark sql.NullInt64
	require.NoError(t, d.QueryRow(`SELECT live_slack_since FROM chat_conversations WHERE id = ?`, conv).Scan(&mark))
	return mark
}

// addStepRow writes a step row the way a finalize finds it, with no step
// event (the finalize backstop's own read).
func addStepRow(t *testing.T, d *db.DB, messageID int64, seq int, name string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, started_at) VALUES (?, ?, ?, ?, 0)`,
		messageID, seq, "tool-"+name, name)
	require.NoError(t, err)
}

// goSlackStepNames are the step names Go's real Claude and Codex translators
// give every Slack connector tool (pinned by TestLIVE01_StepNamesFixture).
func goSlackStepNames(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "slacklive", "testdata", "slack_step_names.json"))
	require.NoError(t, err)
	var byProvider map[string][]string
	require.NoError(t, json.Unmarshal(raw, &byProvider))
	var names []string
	for _, list := range byProvider {
		names = append(names, list...)
	}
	require.NotEmpty(t, names)
	return names
}

func TestLIVE01_GoStoreStepStartMarksWithoutFinalize(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "q")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "a", "search_knowledge")))
	assert.False(t, liveMark(t, d, conv).Valid)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "b", "codex_apps:slack.slack_search_public")))
	assert.Equal(t, sql.NullInt64{Int64: st.AssistantMessageID, Valid: true}, liveMark(t, d, conv))
}

func TestLIVE01_GoStoreEveryGoSlackStepNameMarks(t *testing.T) {
	d, s, _ := newStore(t)
	for _, name := range goSlackStepNames(t) {
		started := newConversation(t, d)
		st := send(t, s, started, "q")
		require.NoError(t, s.Turn(st).Apply(toolStart(st.TurnID, "s", name)))
		assert.True(t, liveMark(t, d, started).Valid, "step start: %s", name)

		finalized := newConversation(t, d)
		st2 := send(t, s, finalized, "q")
		addStepRow(t, d, st2.AssistantMessageID, 0, name)
		require.NoError(t, s.Turn(st2).Finalize(StatusComplete, nil))
		assert.Equal(t, sql.NullInt64{Int64: st2.AssistantMessageID, Valid: true}, liveMark(t, d, finalized),
			"finalize: %s", name)
	}
}

func TestLIVE01_GoStoreFinalizeLeavesUnmarkedWithoutSlackStep(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "q")
	for i, name := range []string{"search_knowledge", "claude_ai_Gmail:search_threads", "list_slack_channels", "list_messages"} {
		addStepRow(t, d, st.AssistantMessageID, i, name)
	}
	require.NoError(t, s.Turn(st).Finalize(StatusComplete, nil))
	assert.False(t, liveMark(t, d, conv).Valid)
}

func TestLIVE01_GoStoreFirstMarkIsKept(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "q")
	_, err := d.Exec(`UPDATE chat_conversations SET live_slack_since = 1 WHERE id = ?`, conv)
	require.NoError(t, err)
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "s", "claude_ai_Slack:slack_read_thread")))
	require.NoError(t, turn.Finalize(StatusComplete, nil))
	assert.Equal(t, sql.NullInt64{Int64: 1, Valid: true}, liveMark(t, d, conv))
}
