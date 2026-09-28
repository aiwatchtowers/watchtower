package chat

import (
	"database/sql"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func msg(id int64, role, text, turn string) db.ChatMessage {
	return db.ChatMessage{ID: id, Role: role, Text: text, TurnID: turn, Status: "complete",
		ParentID: sql.NullInt64{Int64: id - 1, Valid: id > 1}}
}

func TestBuildReplay_Empty(t *testing.T) {
	assert.Equal(t, "", BuildReplay(nil, ReplayCapChars))
}

func TestBuildReplay_RendersRolesAndFrame(t *testing.T) {
	out := BuildReplay([]db.ChatMessage{
		msg(1, "user", "What slipped?", "t1"),
		msg(2, "assistant", "The refunds launch.", "t1"),
		msg(3, "system", "Action applied: created target", ""),
	}, ReplayCapChars)
	assert.True(t, strings.HasPrefix(out, replayHeader+"\n"))
	assert.True(t, strings.HasSuffix(out, replayFooter+"\n\n"), "the caller prepends it to the turn text")
	assert.Contains(t, out, "Owner: What slipped?\n")
	assert.Contains(t, out, "Assistant: The refunds launch.\n")
	assert.Contains(t, out, "System: Action applied: created target\n")
	assert.NotContains(t, out, "omitted")
}

// The empty partial reply the Desktop writes under a legacy unanswered owner
// question (and any other text-less, step-less reply) carries nothing and is
// not replayed as a blank "Assistant" line; a text-less reply WITH steps is.
func TestBuildReplaySteps_SkipsEmptyAssistantRows(t *testing.T) {
	placeholder := msg(2, "assistant", "", "t1")
	placeholder.Status = "partial"
	stepsOnly := msg(4, "assistant", "  ", "t2")
	stepsOnly.Status = "partial"
	out := BuildReplaySteps([]db.ChatMessage{
		msg(1, "user", "Legacy question", "t1"), placeholder,
		msg(3, "user", "Newer question", "t2"), stepsOnly,
	}, map[int64][]string{4: {"search_knowledge: 2 hits"}}, ReplayCapChars)
	assert.Equal(t, 1, strings.Count(out, "Assistant"), "only the reply with steps is replayed: %q", out)
	assert.Contains(t, out, "Owner: Legacy question\nOwner: Newer question\n")
	assert.Contains(t, out, "search_knowledge: 2 hits")
	assert.NotContains(t, out, "omitted")

	lone := msg(1, "assistant", "", "t1")
	assert.Equal(t, "", BuildReplay([]db.ChatMessage{lone}, ReplayCapChars), "nothing left to say → no block")
}

func TestBuildReplay_MarksStoppedAnswers(t *testing.T) {
	m := msg(2, "assistant", "Half an answer", "t1")
	m.Status = "partial"
	out := BuildReplay([]db.ChatMessage{msg(1, "user", "q", "t1"), m}, ReplayCapChars)
	assert.Contains(t, out, "Assistant (stopped early): Half an answer")
}

func TestBuildReplaySteps_OneLinePerStep(t *testing.T) {
	out := BuildReplaySteps([]db.ChatMessage{msg(1, "user", "q", "t1"), msg(2, "assistant", "a", "t1")},
		map[int64][]string{2: {"search_knowledge: 3 results", "get_jira_issue (failed): no such issue"}}, ReplayCapChars)
	assert.Contains(t, out, "Assistant: a\n  · step: search_knowledge: 3 results\n  · step: get_jira_issue (failed): no such issue\n")
}

func TestBuildReplay_CapKeepsNewestAndCountsOmitted(t *testing.T) {
	var path []db.ChatMessage
	for i := int64(1); i <= 10; i++ {
		path = append(path, msg(i, "user", strings.Repeat("x", 90)+string(rune('a'+i-1)), "t"))
	}
	out := BuildReplay(path, 300) // each entry ≈ 98 runes + newline → three fit
	assert.Contains(t, out, "[7 earlier messages omitted]")
	assert.Contains(t, out, strings.Repeat("x", 90)+"j", "the newest message is kept")
	assert.NotContains(t, out, strings.Repeat("x", 90)+"g")
}

func TestBuildReplay_SingleHugeMessageIsTruncatedNotDropped(t *testing.T) {
	out := BuildReplay([]db.ChatMessage{msg(1, "user", strings.Repeat("я", 50_000), "t")}, ReplayCapChars)
	body := strings.TrimSuffix(strings.TrimPrefix(out, replayHeader+"\n"), replayFooter+"\n\n")
	assert.LessOrEqual(t, utf8.RuneCountInString(body), ReplayCapChars+1)
	assert.Contains(t, out, "Owner: яяя")
	assert.True(t, utf8.ValidString(out))
}

func TestHistoryBefore_DropsTheCurrentTurn(t *testing.T) {
	path := []db.ChatMessage{msg(1, "user", "a", "t1"), msg(2, "assistant", "b", "t1"), msg(3, "user", "c", "t2")}
	assert.Len(t, HistoryBefore(path, "t2"), 2, "the user message persisted before the turn is not replayed twice")
	assert.Len(t, HistoryBefore(path, "t9"), 3)
	assert.Len(t, HistoryBefore(path, ""), 3)
	assert.Empty(t, HistoryBefore([]db.ChatMessage{msg(1, "user", "c", "t2")}, "t2"))
}

// TestHistoryBefore_RegenerateDoesNotDuplicateOwnerQuestion pins preflight
// ruling A13: on regenerate the owner's message row is reused under the OLD
// turn id (t1) and only a new assistant row is inserted under the NEW turn id
// (t2). HistoryBefore(path, "t2") strips the trailing assistant(t2) row by
// turn id as usual, but must also drop the now-trailing user(t1) row — it is
// the same text as the turn about to be sent, so replaying it would duplicate
// the owner's question.
func TestHistoryBefore_RegenerateDoesNotDuplicateOwnerQuestion(t *testing.T) {
	path := []db.ChatMessage{msg(1, "user", "q", "t1"), msg(2, "assistant", "", "t2")}
	before := HistoryBefore(path, "t2")
	assert.Empty(t, before, "both the pending regenerate answer and the reused owner question are excluded")
}

func TestReplayFromDB_UsesActivePathAndSteps(t *testing.T) {
	d := db.OpenTestDB(t)
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	insert := func(parent any, role, text, turn string) int64 {
		r, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, turn_id, created_at)
			VALUES (?, ?, ?, ?, ?, 1)`, conv, parent, role, text, turn)
		require.NoError(t, err)
		id, err := r.LastInsertId()
		require.NoError(t, err)
		return id
	}
	q := insert(nil, "user", "what slipped?", "t1")
	a := insert(q, "assistant", "refunds", "t1")
	insert(a, "user", "why?", "t2") // the running turn, persisted before it was sent
	_, err = d.Exec(`INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, ok, summary, started_at)
		VALUES (?, 1, 'x', 'search_knowledge', 1, '2 results', 1)`, a)
	require.NoError(t, err)

	out, err := ReplayFromDB(d, conv, "t2")
	require.NoError(t, err)
	assert.Contains(t, out, "Owner: what slipped?")
	assert.Contains(t, out, "  · step: search_knowledge: 2 results")
	assert.NotContains(t, out, "why?", "the running turn is sent as the turn text, not replayed")
}
