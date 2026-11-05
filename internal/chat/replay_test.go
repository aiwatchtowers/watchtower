package chat

import (
	"database/sql"
	"os"
	"path/filepath"
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

func TestReplayFailedEmptyAssistantIncludesOnlyPriorPathReceipts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "chat.db")
	d, err := db.Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	_, err = d.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at) VALUES(1,1,1),(2,1,1)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_messages(id,conversation_id,parent_id,role,text,turn_id,status,created_at) VALUES
 (1,1,NULL,'user','previous question','prior','complete',1),
 (2,1,1,'assistant','','prior','error',2),
 (3,1,2,'user','current question','current','complete',3),
 (4,1,3,'assistant','','current','partial',4),
 (5,1,1,'assistant','abandoned','branch','complete',5)`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE chat_conversations SET active_leaf_message_id=4 WHERE id=1`)
	require.NoError(t, err)
	receipt, err := d.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"secret":"do not replay"}`, Reason: "private reason", Surface: "main", ConversationID: 1, TurnID: "prior"})
	require.NoError(t, err)
	_, err = d.TransitionAgentAction(receipt, []string{"pending"}, "failed", `{"secret":"private result"}`, "private error")
	require.NoError(t, err)
	for _, a := range []db.AgentAction{
		{Tool: "current_tool", ConversationID: 1, TurnID: "current"},
		{Tool: "branch_tool", ConversationID: 1, TurnID: "branch"},
		{Tool: "other_conversation", ConversationID: 2, TurnID: "prior"},
	} {
		a.ArgsJSON = "{}"
		_, err = d.InsertAgentAction(a)
		require.NoError(t, err)
	}
	require.NoError(t, d.Close())
	d, err = db.Open(path)
	require.NoError(t, err)
	out, err := ReplayFromDB(d, 1, "current")
	require.NoError(t, err)
	require.Contains(t, out, "create_target: failed")
	require.Contains(t, out, "persisted receipt; do not repeat")
	require.Contains(t, out, "result recorded; error recorded")
	for _, s := range []string{"current_tool", "branch_tool", "other_conversation", "current question", "private", "do not replay", "abandoned"} {
		require.NotContains(t, out, s)
	}
	// Regenerate removes both the new assistant and reused owner row. A receipt
	// belonging to that owner turn cannot become prior history accidentally.
	_, err = d.Exec(`DELETE FROM chat_messages WHERE id=5`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE chat_messages SET turn_id='regenerate' WHERE id=4`)
	require.NoError(t, err)
	out, err = ReplayFromDB(d, 1, "regenerate")
	require.NoError(t, err)
	require.NotContains(t, out, "current_tool")
	require.NotContains(t, out, "current question")
}

// Earlier turns' text files are replayed newest first within the byte
// budget; what does not fit, an image and a file gone from disk are named
// with the reason instead, and the running turn's files are never replayed.
func TestReplayFiles_NewestFirstWithinBudget(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, data []byte) string {
		p := filepath.Join(dir, name)
		require.NoError(t, os.WriteFile(p, data, 0o600))
		return p
	}
	hist := []db.ChatMessage{
		msg(1, "user", "old", "t1"), msg(2, "assistant", "ok", "t1"),
		msg(3, "user", "new", "t2"), msg(4, "assistant", "ok", "t2"),
	}
	files := map[int64][]db.ChatProjectFile{
		1: {{Name: "old.csv", Mime: "text/csv", Path: write("old.csv", []byte(strings.Repeat("o", 60)))}},
		3: {
			{Name: "new.csv", Mime: "text/csv", Path: write("new.csv", []byte(strings.Repeat("n", 60)))},
			{Name: "shot.png", Mime: "image/png", Path: write("shot.png", fixturePNG)},
			{Name: "gone.txt", Mime: "text/plain", Path: filepath.Join(dir, "gone.txt")},
		},
	}
	out := replayFiles(hist, files, 100)
	assert.True(t, strings.HasPrefix(out, replayFilesHeader+"\n"), out)
	assert.True(t, strings.HasSuffix(out, replayFilesFooter+"\n\n"), out)
	assert.Contains(t, out, "<file name=\"new.csv\">\n"+strings.Repeat("n", 60)+"\n</file>")
	assert.NotContains(t, out, strings.Repeat("o", 60), "the older file is over the budget")
	assert.Contains(t, out, `[file "old.csv" not replayed: over the replay's 100-byte budget for earlier files]`)
	assert.Contains(t, out, `[file "shot.png" not replayed: images and PDFs are not replayed]`)
	assert.Contains(t, out, `[file "gone.txt" not replayed: file not found or unreadable]`)
	assert.Less(t, strings.Index(out, "new.csv"), strings.Index(out, "old.csv"), "newest first")

	assert.Empty(t, replayFiles(hist, nil, 100), "no files → no block")
}

func TestReplayFromDB_ReplaysEarlierTextFiles(t *testing.T) {
	d, conv := seedConversation(t)
	ids := map[string]int64{}
	for _, turn := range []string{"t1", "t2"} {
		var id int64
		require.NoError(t, d.QueryRow(`SELECT id FROM chat_messages WHERE role = 'user' AND turn_id = ?`, turn).Scan(&id))
		ids[turn] = id
	}
	linkAttachment(t, d, conv, ids["t1"], "a.csv", "text/csv", writeAttachmentFixture(t, "a.csv", []byte("a,b\n1,2")))
	linkAttachment(t, d, conv, ids["t2"], "now.csv", "text/csv", writeAttachmentFixture(t, "now.csv", []byte("sent with the running turn")))

	out, err := ReplayFromDB(d, conv, "t2")
	require.NoError(t, err)
	assert.Contains(t, out, "<file name=\"a.csv\">\na,b\n1,2\n</file>")
	assert.NotContains(t, out, "now.csv", "the running turn's files travel with the turn, not the replay")
	assert.Less(t, strings.Index(out, replayFilesFooter), strings.Index(out, replayHeader), "files first, the transcript ends the block")
}

// A file sent again shares its stored copy (one per content): it is replayed
// once, at its newest place, never inlined twice or noted as over the budget.
func TestReplayFiles_ResentFileIsReplayedOnce(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.csv")
	require.NoError(t, os.WriteFile(p, []byte(strings.Repeat("a", 60)), 0o600))
	f := db.ChatProjectFile{Name: "a.csv", Mime: "text/csv", Path: p, Size: 60}
	hist := []db.ChatMessage{msg(1, "user", "here", "t1"), msg(2, "assistant", "ok", "t1"), msg(3, "user", "again", "t2")}
	out := replayFiles(hist, map[int64][]db.ChatProjectFile{1: {f}, 3: {f}}, 100)
	assert.Equal(t, 1, strings.Count(out, `<file name="a.csv">`), out)
	assert.NotContains(t, out, "not replayed")
}

// The stored size rules a file out before it is read.
func TestReplayFiles_StoredSizeOverBudgetIsNotRead(t *testing.T) {
	gone := filepath.Join(t.TempDir(), "big.csv") // never created: a read would say "unreadable"
	hist := []db.ChatMessage{msg(1, "user", "here", "t1")}
	out := replayFiles(hist, map[int64][]db.ChatProjectFile{1: {{Name: "big.csv", Mime: "text/csv", Path: gone, Size: 101}}}, 100)
	assert.Contains(t, out, `[file "big.csv" not replayed: over the replay's 100-byte budget for earlier files]`)
}
