package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestListRecentChatTurnsAbsentTables: a CLI-only install has never run the
// Desktop app, so the Swift-owned chat tables do not exist — the read is a
// clean empty no-op, never an error.
func TestListRecentChatTurnsAbsentTables(t *testing.T) {
	db := openTestDB(t)

	turns, err := db.ListRecentChatTurns("target", "7", 10)
	if err != nil {
		t.Fatalf("absent chat tables must read empty, got error: %v", err)
	}
	if turns != nil {
		t.Fatalf("absent chat tables must yield nil turns, got %+v", turns)
	}
}

// TestListRecentChatTurnsOrderingAndLimit: the reader returns the most recent
// turns for one (context_type, context_id) pair, newest LAST, spanning every
// conversation of that context, and never leaks another context's turns.
func TestListRecentChatTurnsOrderingAndLimit(t *testing.T) {
	db := openTestDB(t)

	base := float64(time.Now().Add(-time.Hour).Unix())
	convA := insertChatConversation(t, db, "target", "7")
	convB := insertChatConversation(t, db, "target", "7") // a second tab on the same target
	other := insertChatConversation(t, db, "target", "8")
	situation := insertChatConversation(t, db, "situation", "7")

	insertChatMessage(t, db, convA, "user", "first", base)
	insertChatMessage(t, db, convA, "assistant", "second", base+10)
	insertChatMessage(t, db, convB, "system", "Action applied: marked sub-item done.", base+20)
	insertChatMessage(t, db, convA, "user", "fourth", base+30)
	insertChatMessage(t, db, other, "user", "other target", base+40)
	insertChatMessage(t, db, situation, "user", "other context type", base+40)

	turns, err := db.ListRecentChatTurns("target", "7", 10)
	if err != nil {
		t.Fatalf("ListRecentChatTurns: %v", err)
	}
	if len(turns) != 4 {
		t.Fatalf("expected 4 turns for target/7, got %d: %+v", len(turns), turns)
	}
	wantTexts := []string{"first", "second", "Action applied: marked sub-item done.", "fourth"}
	for i, want := range wantTexts {
		if turns[i].Text != want {
			t.Errorf("turn %d text = %q, want %q (newest must be last)", i, turns[i].Text, want)
		}
	}
	if turns[2].Role != "system" {
		t.Errorf("system turns must be included with their role, got %q", turns[2].Role)
	}
	if turns[3].CreatedAt != int64(base+30) {
		t.Errorf("created_at = %d, want %d", turns[3].CreatedAt, int64(base+30))
	}

	// The limit keeps the RECENT tail, still newest-last.
	capped, err := db.ListRecentChatTurns("target", "7", 2)
	if err != nil {
		t.Fatalf("ListRecentChatTurns capped: %v", err)
	}
	if len(capped) != 2 {
		t.Fatalf("expected 2 capped turns, got %d: %+v", len(capped), capped)
	}
	if capped[0].Text != "Action applied: marked sub-item done." || capped[1].Text != "fourth" {
		t.Errorf("cap must keep the newest turns, got %+v", capped)
	}
}

// TestListRecentChatTurnsDegenerateArgs: valid-but-degenerate input (no
// context, no limit, an unknown context) is a clean empty read, not an error.
func TestListRecentChatTurnsDegenerateArgs(t *testing.T) {
	db := openTestDB(t)
	conv := insertChatConversation(t, db, "target", "7")
	insertChatMessage(t, db, conv, "user", "hello", float64(time.Now().Unix()))

	cases := []struct {
		name    string
		ctxType string
		ctxID   string
		limit   int
	}{
		{"zero limit", "target", "7", 0},
		{"negative limit", "target", "7", -3},
		{"empty context type", "", "7", 10},
		{"empty context id", "target", "", 10},
		{"unknown target", "target", "999", 10},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			turns, err := db.ListRecentChatTurns(tc.ctxType, tc.ctxID, tc.limit)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(turns) != 0 {
				t.Fatalf("expected no turns, got %+v", turns)
			}
		})
	}
}

// insertBranchMessage inserts one chat message under parent (0 = a root) with
// a turn id — the redesigned chat's write shape.
func insertBranchMessage(t *testing.T, d *DB, conv, parent int64, role, text, turnID string) int64 {
	t.Helper()
	var p any
	if parent != 0 {
		p = parent
	}
	res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, turn_id, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`, conv, p, role, text, turnID, float64(time.Now().Unix()))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func setActiveLeaf(t *testing.T, d *DB, conv, leaf int64) {
	t.Helper()
	_, err := d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, leaf, conv)
	require.NoError(t, err)
}

func pathTexts(msgs []ChatMessage) []string {
	out := make([]string, len(msgs))
	for i, m := range msgs {
		out[i] = m.Text
	}
	return out
}

func TestActiveChatPath_FollowsActiveLeaf(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "", "")
	q := insertBranchMessage(t, d, conv, 0, "user", "question", "t1")
	insertBranchMessage(t, d, conv, q, "assistant", "answer v1", "t1")
	v2 := insertBranchMessage(t, d, conv, q, "assistant", "answer v2", "t1") // regenerate = sibling
	follow := insertBranchMessage(t, d, conv, v2, "user", "follow-up", "t2")

	path, err := d.ActiveChatPath(conv)
	require.NoError(t, err)
	assert.Equal(t, []string{"question", "answer v1", "answer v2", "follow-up"}, pathTexts(path),
		"a NULL leaf falls back to linear id order")

	setActiveLeaf(t, d, conv, follow)
	path, err = d.ActiveChatPath(conv)
	require.NoError(t, err)
	assert.Equal(t, []string{"question", "answer v2", "follow-up"}, pathTexts(path))
	assert.Equal(t, "t2", path[2].TurnID)

	setActiveLeaf(t, d, conv, 999999)
	path, err = d.ActiveChatPath(conv)
	require.NoError(t, err)
	assert.Len(t, path, 4, "a dangling leaf falls back to linear order instead of hiding the conversation")

	path, err = d.ActiveChatPath(424242)
	require.NoError(t, err)
	assert.Nil(t, path, "unknown conversation reads empty")
}

func TestGetChatConversationAndSetTitle(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "", "")

	c, err := d.GetChatConversation(conv)
	require.NoError(t, err)
	require.NotNil(t, c)
	assert.Equal(t, "prefix", c.TitleSource)
	assert.False(t, c.ProjectID.Valid)

	written, err := d.SetChatTitle(conv, "Payments rollout", "ai")
	require.NoError(t, err)
	assert.True(t, written)
	c, err = d.GetChatConversation(conv)
	require.NoError(t, err)
	assert.Equal(t, "Payments rollout", c.Title)
	assert.Equal(t, "ai", c.TitleSource)

	_, err = d.Exec(`UPDATE chat_conversations SET title = 'Mine', title_source = 'user' WHERE id = ?`, conv)
	require.NoError(t, err)
	written, err = d.SetChatTitle(conv, "AI would overwrite", "ai")
	require.NoError(t, err)
	assert.False(t, written, "an owner-set title is never overwritten")
	c, err = d.GetChatConversation(conv)
	require.NoError(t, err)
	assert.Equal(t, "Mine", c.Title)

	_, err = d.SetChatTitle(conv, "x", "robot")
	assert.Error(t, err)

	missing, err := d.GetChatConversation(999999)
	require.NoError(t, err)
	assert.Nil(t, missing)
}

func TestGetChatProjectContext(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO chat_projects (name, instructions, created_at, updated_at)
		VALUES ('Payments', 'Answer in bullets.', 1, 1)`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref, label)
		VALUES (?, 'jira_project', 'PAY', 'Payments board')`, pid)
	require.NoError(t, err)
	for _, f := range []struct{ name, mime string }{
		{"notes.md", "text/markdown"}, {"arch.png", "image/png"}, {"spec.pdf", "application/pdf"},
	} {
		_, err = d.Exec(`INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
			VALUES (?, ?, ?, 10, ?, ?, 1)`, pid, f.name, f.mime, "/tmp/"+f.name, "h-"+f.name)
		require.NoError(t, err)
	}

	pc, err := d.GetChatProjectContext(pid)
	require.NoError(t, err)
	require.NotNil(t, pc)
	assert.Equal(t, "Payments", pc.Name)
	assert.Equal(t, "Answer in bullets.", pc.Instructions)
	assert.Equal(t, []ChatProjectSource{{Kind: "jira_project", Ref: "PAY", Label: "Payments board"}}, pc.Sources)
	require.Len(t, pc.TextFiles, 1)
	assert.Equal(t, "notes.md", pc.TextFiles[0].Name)
	require.Len(t, pc.BinaryFiles, 2)

	none, err := d.GetChatProjectContext(999999)
	require.NoError(t, err)
	assert.Nil(t, none)
}

func TestChatStepSummaries(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "", "")
	msg := insertBranchMessage(t, d, conv, 0, "assistant", "answer", "t1")
	_, err := d.Exec(`INSERT INTO chat_turn_steps
		(message_id, seq, tool_id, name, args_json, ok, summary, sources_json, started_at, ended_at) VALUES
		(?, 2, 'b', 'get_jira_issue', '{}', 0, 'no such issue', '[]', 2, 3),
		(?, 1, 'a', 'search_knowledge', '{}', 1, '3 results', '[]', 1, 2)`, msg, msg)
	require.NoError(t, err)

	got, err := d.ChatStepSummaries([]int64{msg})
	require.NoError(t, err)
	assert.Equal(t, []string{"search_knowledge: 3 results", "get_jira_issue (failed): no such issue"}, got[msg])

	empty, err := d.ChatStepSummaries(nil)
	require.NoError(t, err)
	assert.Empty(t, empty)
}

// TestListRecentChatTurns_ActiveBranchOnly: the next-step prompt excerpt
// never quotes an abandoned branch (spec §2.2).
func TestListRecentChatTurns_ActiveBranchOnly(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "target", "42")
	old := insertBranchMessage(t, d, conv, 0, "user", "old wording", "t1")
	insertBranchMessage(t, d, conv, old, "assistant", "reply to old", "t1")
	edited := insertBranchMessage(t, d, conv, 0, "user", "edited wording", "t2")
	leaf := insertBranchMessage(t, d, conv, edited, "assistant", "reply to edit", "t2")
	setActiveLeaf(t, d, conv, leaf)

	turns, err := d.ListRecentChatTurns("target", "42", 10)
	require.NoError(t, err)
	var texts []string
	for _, tr := range turns {
		texts = append(texts, tr.Text)
	}
	assert.Equal(t, []string{"edited wording", "reply to edit"}, texts)
}

// TestListOwnerChatTurns_ActiveBranchOnly: memory's chat ingest reads only the
// active branch; a conversation without an active leaf (every Discuss chat,
// every legacy row) keeps its full linear history.
func TestListOwnerChatTurns_ActiveBranchOnly(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "situation", "42")
	old := insertBranchMessage(t, d, conv, 0, "user", "old wording", "t1")
	insertBranchMessage(t, d, conv, old, "assistant", "reply to old", "t1")
	edited := insertBranchMessage(t, d, conv, 0, "user", "edited wording", "t2")
	leaf := insertBranchMessage(t, d, conv, edited, "assistant", "reply to edit", "t2")
	setActiveLeaf(t, d, conv, leaf)

	linear := insertChatConversation(t, d, "situation", "43")
	insertChatMessage(t, d, linear, "user", "discuss turn", 5)

	turns, err := d.ListOwnerChatTurns(0, []string{"situation"})
	require.NoError(t, err)
	var texts []string
	for _, tr := range turns {
		texts = append(texts, tr.Text)
	}
	assert.Equal(t, []string{"edited wording", "discuss turn"}, texts)
}
