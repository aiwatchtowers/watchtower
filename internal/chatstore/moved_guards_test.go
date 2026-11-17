package chatstore

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/tower/api"
)

// The guards of the Desktop's Swift turn store (ChatTurnStore, deleted by
// mobile Inbox Task 18): Go writes every chat row now, so the row side of
// these contracts is pinned here, under their Swift names (docs/inventory/
// chat.md CHAT-02 and LIVE-01).

func toolEnd(turn, id string, ok bool, summary string, sources ...chat.Source) chat.Event {
	e := ev(chat.EventToolEnd, turn)
	e.ID, e.OK, e.Summary, e.Sources = id, &ok, summary, sources
	return e
}

func toolWait(turn, id string, action int64) chat.Event {
	e := ev(chat.EventToolWait, turn)
	e.ID, e.ActionID, e.Message = id, action, "Waiting for your approval"
	return e
}

type stepRow struct {
	ToolID, Name, Summary string
	OK                    sql.NullBool
	Ended                 bool
}

func stepRows(t *testing.T, s *Store, messageID int64) []stepRow {
	t.Helper()
	rows, err := s.db.Query(`SELECT tool_id, name, summary, ok, ended_at IS NOT NULL FROM chat_turn_steps
		WHERE message_id = ? ORDER BY seq`, messageID)
	require.NoError(t, err)
	defer rows.Close()
	var out []stepRow
	for rows.Next() {
		var r stepRow
		require.NoError(t, rows.Scan(&r.ToolID, &r.Name, &r.Summary, &r.OK, &r.Ended))
		out = append(out, r)
	}
	require.NoError(t, rows.Err())
	return out
}

// TestChat02ToolStepsArePersistedImmediately: every tool call is on disk as
// it happens — running at its start, finished with its sources at its end
// (BEHAVIOR CHAT-02 — see docs/inventory/chat.md).
func TestChat02ToolStepsArePersistedImmediately(t *testing.T) {
	d, s, _ := newStore(t)
	st := send(t, s, newConversation(t, d), "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "a", "search_knowledge")))
	steps := stepRows(t, s, st.AssistantMessageID)
	require.Len(t, steps, 1)
	assert.False(t, steps[0].Ended, "running")
	require.NoError(t, turn.Apply(toolEnd(st.TurnID, "a", true, "3 hits", chat.Source{Kind: "slack", Title: "x", Ref: "r"})))
	steps = stepRows(t, s, st.AssistantMessageID)
	require.Len(t, steps, 1)
	assert.True(t, steps[0].Ended)
	assert.Equal(t, sql.NullBool{Bool: true, Valid: true}, steps[0].OK)
	var sources string
	require.NoError(t, d.QueryRow(`SELECT sources_json FROM chat_turn_steps WHERE message_id = ?`, st.AssistantMessageID).Scan(&sources))
	var decoded []chat.Source
	require.NoError(t, json.Unmarshal([]byte(sources), &decoded))
	require.Len(t, decoded, 1)
	assert.Equal(t, "r", decoded[0].Ref)
}

// TestChat02WaitingStepIsVisibleUntilItEnds: a call waiting for the owner's
// approval is a waiting step live only; the rows see the usual start and
// end, and a wait whose start never came still writes a nameless start
// (BEHAVIOR CHAT-02 — see docs/inventory/chat.md).
func TestChat02WaitingStepIsVisibleUntilItEnds(t *testing.T) {
	d, s, _ := newStore(t)
	st := send(t, s, newConversation(t, d), "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "a", "mcp__claude_ai_Gmail__send")))
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "b", "mcp__claude_ai_Docs__create")))
	require.NoError(t, turn.Apply(toolWait(st.TurnID, "a", 41)))
	require.NoError(t, turn.Apply(toolWait(st.TurnID, "b", 42)))
	require.NoError(t, turn.Apply(toolWait(st.TurnID, "orphan", 43)))
	live := turn.Steps()
	require.Len(t, live, 3)
	assert.Equal(t, []StepState{StepWaiting, StepWaiting, StepWaiting}, []StepState{live[0].State, live[1].State, live[2].State})
	rows := stepRows(t, s, st.AssistantMessageID)
	require.Len(t, rows, 3, "the orphan wait wrote its start")
	assert.Equal(t, []string{"a", "b", "orphan"}, []string{rows[0].ToolID, rows[1].ToolID, rows[2].ToolID})
	for _, r := range rows {
		assert.False(t, r.Ended, "waiting is never persisted: %s is a running row", r.ToolID)
	}
	require.NoError(t, turn.Apply(toolEnd(st.TurnID, "a", false, "not approved within 15 minutes")))
	require.NoError(t, turn.Apply(toolEnd(st.TurnID, "b", true, "created")))
	rows = stepRows(t, s, st.AssistantMessageID)
	assert.Equal(t, "not approved within 15 minutes", rows[0].Summary)
	assert.Equal(t, sql.NullBool{Bool: false, Valid: true}, rows[0].OK)
	assert.Equal(t, sql.NullBool{Bool: true, Valid: true}, rows[1].OK)
}

func liveMark(t *testing.T, s *Store, conv int64) sql.NullInt64 {
	t.Helper()
	var mark sql.NullInt64
	require.NoError(t, s.db.QueryRow(`SELECT live_slack_since FROM chat_conversations WHERE id = ?`, conv).Scan(&mark))
	return mark
}

// insertStep writes a step row as the session left it before the end.
func insertStep(t *testing.T, s *Store, messageID int64, seq int, name string) {
	t.Helper()
	_, err := s.db.Exec(`INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, started_at) VALUES (?, ?, ?, ?, 0)`,
		messageID, seq, "tool-"+name, name)
	require.NoError(t, err)
}

func finishTurn(t *testing.T, turn *Turn, st Started) {
	t.Helper()
	e := ev(chat.EventTurnDone, st.TurnID)
	e.Status = chat.StatusComplete
	require.NoError(t, turn.Apply(e))
}

// TestFinalizeMarksConversationOnSlackStep (BEHAVIOR LIVE-01): the turn's
// end marks a conversation whose steps include a Slack connector call.
func TestFinalizeMarksConversationOnSlackStep(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	insertStep(t, s, st.AssistantMessageID, 0, "search_knowledge")
	insertStep(t, s, st.AssistantMessageID, 1, "claude_ai_Slack:slack_search_public")
	finishTurn(t, turn, st)
	assert.Equal(t, sql.NullInt64{Int64: st.AssistantMessageID, Valid: true}, liveMark(t, s, conv))
}

// TestStepStartMarksWithoutFinalize (BEHAVIOR LIVE-01): a Slack step marks
// the conversation when it starts, before any end.
func TestStepStartMarksWithoutFinalize(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "a", "search_knowledge")))
	assert.False(t, liveMark(t, s, conv).Valid)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "b", "codex_apps:slack.slack_search_public")))
	assert.Equal(t, sql.NullInt64{Int64: st.AssistantMessageID, Valid: true}, liveMark(t, s, conv))
}

// TestFinalizeMarksConversationOnCodexSlackStep (BEHAVIOR LIVE-01).
func TestFinalizeMarksConversationOnCodexSlackStep(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	insertStep(t, s, st.AssistantMessageID, 0, "codex_apps:slack.slack_read_channel")
	finishTurn(t, turn, st)
	assert.Equal(t, sql.NullInt64{Int64: st.AssistantMessageID, Valid: true}, liveMark(t, s, conv))
}

// TestFinalizeLeavesUnmarkedWithoutSlackStep (BEHAVIOR LIVE-01): other
// connectors and Watchtower's own Slack tools never mark.
func TestFinalizeLeavesUnmarkedWithoutSlackStep(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	for i, name := range []string{"search_knowledge", "claude_ai_Gmail:search_threads", "list_slack_channels", "list_messages"} {
		insertStep(t, s, st.AssistantMessageID, i, name)
	}
	finishTurn(t, turn, st)
	assert.False(t, liveMark(t, s, conv).Valid)
}

// TestFirstMarkIsKept (BEHAVIOR LIVE-01): a marked conversation keeps its first mark.
func TestFirstMarkIsKept(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	insertStep(t, s, st.AssistantMessageID, 0, "claude_ai_Slack:slack_read_thread")
	_, err := d.Exec(`UPDATE chat_conversations SET live_slack_since = 1 WHERE id = ?`, conv)
	require.NoError(t, err)
	finishTurn(t, turn, st)
	assert.Equal(t, sql.NullInt64{Int64: 1, Valid: true}, liveMark(t, s, conv))
}

// TestEveryGoSlackStepNameMarks (BEHAVIOR LIVE-01): every Slack connector
// step name the translators produce (internal/slacklive's fixture) marks at
// its start and at the turn's end.
func TestEveryGoSlackStepNameMarks(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "slacklive", "testdata", "slack_step_names.json"))
	require.NoError(t, err)
	var names map[string][]string
	require.NoError(t, json.Unmarshal(b, &names))
	require.NotEmpty(t, names["claude"])
	require.NotEmpty(t, names["codex"])
	d, s, _ := newStore(t)
	for _, name := range append(names["claude"], names["codex"]...) {
		assert.True(t, isSlackConnectorStep(name), name)
		conv := newConversation(t, d)
		st := send(t, s, conv, "start "+name)
		require.NoError(t, s.Turn(st).Apply(toolStart(st.TurnID, "a", name)))
		assert.True(t, liveMark(t, s, conv).Valid, "step start: %s", name)

		conv2 := newConversation(t, d)
		st2 := send(t, s, conv2, "end "+name)
		turn := s.Turn(st2)
		insertStep(t, s, st2.AssistantMessageID, 0, name)
		finishTurn(t, turn, st2)
		assert.True(t, liveMark(t, s, conv2).Valid, "finalize: %s", name)
	}
}

// TestKeepRefusedForLiveConversation (BEHAVIOR LIVE-01): keeping an
// artifact of a conversation that used Live Slack is refused, nothing kept.
func TestKeepRefusedForLiveConversation(t *testing.T) {
	tw, d, _ := chatTower(t)
	conv := newConversation(t, d)
	_, err := d.Exec(`INSERT INTO chat_messages (id, conversation_id, role, text, created_at, turn_id, status)
		VALUES (9, ?, 'assistant', 'x', 1, 't', 'complete')`, conv)
	require.NoError(t, err)
	keep := func(id string) api.Response {
		return callChat(t, tw, "chat.artifact.keep", id, json.RawMessage(`{"conversation_id":`+strconv.FormatInt(conv, 10)+`,"artifact_key":"plan","version":1}`), "socket")
	}
	require.Equal(t, api.StatusOK, keep("k1").Status)
	unkeep := callChat(t, tw, "chat.artifact.unkeep", "u1", json.RawMessage(`{"conversation_id":`+strconv.FormatInt(conv, 10)+`,"artifact_key":"plan"}`), "socket")
	require.Equal(t, api.StatusOK, unkeep.Status)
	_, err = d.Exec(`UPDATE chat_conversations SET live_slack_since = 9 WHERE id = ?`, conv)
	require.NoError(t, err)
	resp := keep("k2")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeNotPermitted, resp.Refusal.Code)
	var kept int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_knowledge_artifacts WHERE conversation_id = ?`, conv).Scan(&kept))
	assert.Zero(t, kept)
}
