package db

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Migration 00154: idea_mentions.source accepts 'chat' (the rebuild keeps the
// rows and the AUTOINCREMENT mark), ideas.chat_born defaults 0, the chat floor
// is seeded to the newest chat message id at migration time (no backfill of
// history), and kept artifacts follow their conversation's deletion.
func TestMigration00154_ChatKnowledge(t *testing.T) {
	t.Parallel()
	d, err := Open(filepath.Join(t.TempDir(), "chat-knowledge.db"))
	require.NoError(t, err)
	defer d.Close()

	require.NoError(t, gooseDownTo(d.DB, "migrations", 153))
	_, err = d.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'acme')`)
	require.NoError(t, err)
	res, err := d.Exec(`INSERT INTO ideas (kind, title) VALUES ('decision', 'pre-existing')`)
	require.NoError(t, err)
	ideaID, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO idea_mentions (id, idea_id, source, ref) VALUES (5, ?, 'slack', 'C1:1.1'), (70, ?, 'jira', 'X-1')`, ideaID, ideaID)
	require.NoError(t, err)
	// Only sqlite_sequence still remembers 70 once the row is gone.
	_, err = d.Exec(`DELETE FROM idea_mentions WHERE id = 70`)
	require.NoError(t, err)
	conv := insertChatConversation(t, d, "", "")
	insertChatMessage(t, d, conv, "user", "one", 1)
	lastMsg := insertChatMessage(t, d, conv, "assistant", "two", 2)

	require.NoError(t, gooseUp(d.DB, "migrations"))

	floor, err := d.GetIdeasChatFloor()
	require.NoError(t, err)
	assert.Equal(t, lastMsg, floor, "the chat floor starts at the newest message: history is not mined")

	var src string
	require.NoError(t, d.QueryRow(`SELECT source FROM idea_mentions WHERE id = 5`).Scan(&src))
	assert.Equal(t, "slack", src, "existing mentions survive the rebuild")

	res, err = d.Exec(`INSERT INTO idea_mentions (idea_id, source, ref) VALUES (?, 'chat', 'chat:1:2')`, ideaID)
	require.NoError(t, err)
	mid, err := res.LastInsertId()
	require.NoError(t, err)
	assert.Greater(t, mid, int64(70), "the AUTOINCREMENT mark is carried")
	_, err = d.Exec(`INSERT INTO idea_mentions (idea_id, source, ref) VALUES (?, 'bogus', 'x')`, ideaID)
	require.Error(t, err, "the CHECK still rejects unknown sources")

	var chatBorn int
	require.NoError(t, d.QueryRow(`SELECT chat_born FROM ideas WHERE id = ?`, ideaID).Scan(&chatBorn))
	assert.Equal(t, 0, chatBorn)

	_, err = d.Exec(`INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at)
		VALUES (?, 'plan', 1, '2026-10-24T10:00:00Z')`, conv)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_knowledge_artifacts`).Scan(&n))
	assert.Equal(t, 0, n, "deleting a conversation deletes its kept artifacts")

	// Down drops the chat mentions and the new columns; Up again works.
	require.NoError(t, gooseDownTo(d.DB, "migrations", 153))
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM idea_mentions WHERE source = 'chat'`).Scan(&n))
	assert.Equal(t, 0, n)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM idea_mentions WHERE id = 5`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, gooseUp(d.DB, "migrations"))
}

func TestIdeasChatFloor_RoundTrip(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO workspace (id, name, domain) VALUES ('T1', 'acme', 'acme')`)
	require.NoError(t, err)
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.SetIdeasChatFloorTx(tx, 42))
	require.NoError(t, tx.Commit())
	got, err := d.GetIdeasChatFloor()
	require.NoError(t, err)
	assert.Equal(t, int64(42), got)
}

func TestIdeasChatFloor_NoWorkspaceRow(t *testing.T) {
	d := openTestDB(t)
	got, err := d.GetIdeasChatFloor()
	require.NoError(t, err)
	assert.Equal(t, int64(0), got)
	tx, err := d.Begin()
	require.NoError(t, err)
	defer func() { _ = tx.Rollback() }()
	require.Error(t, d.SetIdeasChatFloorTx(tx, 1), "a missing workspace row is an error, not a silent no-op")
}

func TestCreateIdeaTx_WritesChatBorn(t *testing.T) {
	d := openTestDB(t)
	tx, err := d.Begin()
	require.NoError(t, err)
	id, err := d.CreateIdeaTx(tx, Idea{Kind: "decision", Title: "from a chat", ChatBorn: true})
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	idea, err := d.GetIdea(id)
	require.NoError(t, err)
	assert.True(t, idea.ChatBorn)
}

func TestListChatTurnsForIdeas(t *testing.T) {
	d := openTestDB(t)
	cutoff := time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)
	at := func(offset time.Duration) float64 { return float64(cutoff.Add(offset).Unix()) }

	plain := insertChatConversation(t, d, "", "")
	_, err := d.Exec(`UPDATE chat_conversations SET title = 'Rollout plan' WHERE id = ?`, plain)
	require.NoError(t, err)
	ideaConv := insertChatConversation(t, d, "idea", "3")

	below := insertChatMessage(t, d, plain, "user", "already mined", at(-time.Hour))
	first := insertChatMessage(t, d, plain, "user", "we ship on Monday", at(-time.Hour))
	insertChatMessage(t, d, ideaConv, "user", "discussing an idea", at(-time.Hour))
	second := insertChatMessage(t, d, plain, "assistant", "agreed", at(0))
	insertChatMessage(t, d, plain, "tool", "noise", at(-time.Minute))
	failed := insertChatMessage(t, d, plain, "assistant", "half an error", at(-time.Minute))
	_, err = d.Exec(`UPDATE chat_messages SET status = 'error' WHERE id = ?`, failed)
	require.NoError(t, err)
	stopped := insertChatMessage(t, d, plain, "assistant", "stopped reply", at(-time.Minute))
	_, err = d.Exec(`UPDATE chat_messages SET status = 'partial' WHERE id = ?`, stopped)
	require.NoError(t, err)

	// A branched conversation: root → (offBranch | onBranch), active leaf onBranch.
	branched := insertChatConversation(t, d, "target", "7")
	root := insertBranchMessage(t, d, branched, 0, "user", "root", "t1")
	insertBranchMessage(t, d, branched, root, "assistant", "abandoned reply", "t2")
	onBranch := insertBranchMessage(t, d, branched, root, "assistant", "kept reply", "t3")
	setActiveLeaf(t, d, branched, onBranch)
	_, err = d.Exec(`UPDATE chat_messages SET created_at = ? WHERE conversation_id = ?`, at(-time.Minute), branched)
	require.NoError(t, err)

	// A message past the cutoff stops the listing: a later id stamped older
	// (clock skew) is not returned above it, so a floor can never pass it.
	insertChatMessage(t, d, plain, "user", "too fresh", at(time.Second))
	insertChatMessage(t, d, plain, "user", "skewed older", at(-time.Hour))

	ids := func(turns []ChatTurnForIdeas) []int64 {
		out := make([]int64, len(turns))
		for i, turn := range turns {
			out[i] = turn.ID
		}
		return out
	}
	got, err := d.ListChatTurnsForIdeas(below, cutoff.Format(time.RFC3339), 100)
	require.NoError(t, err)
	assert.Equal(t, []int64{first, second, stopped, root, onBranch}, ids(got),
		"error replies are left out, a stopped (partial) reply is kept")
	assert.Equal(t, ChatTurnForIdeas{
		ID: first, ConversationID: plain, ConversationTitle: "Rollout plan",
		Role: "user", Text: "we ship on Monday", CreatedAt: cutoff.Add(-time.Hour).Format(time.RFC3339),
	}, got[0])

	limited, err := d.ListChatTurnsForIdeas(below, cutoff.Format(time.RFC3339), 1)
	require.NoError(t, err)
	require.Len(t, limited, 1)
	assert.Equal(t, first, limited[0].ID)

	_, err = d.ListChatTurnsForIdeas(0, "not a time", 10)
	require.Error(t, err)
	_, err = d.ListChatTurnsForIdeas(below, cutoff.Format(time.RFC3339), 0)
	require.Error(t, err, "a non-positive limit is refused, never read as no limit")
}

func TestKnowledgeVisibleIdeaCond(t *testing.T) {
	assert.Equal(t, "NOT (chat_born = 1 AND status IN ('proposed','not_now','rejected','dropped'))", KnowledgeVisibleIdeaCond(""))
	assert.Equal(t, "NOT (i.chat_born = 1 AND i.status IN ('proposed','not_now','rejected','dropped'))", KnowledgeVisibleIdeaCond("i"))

	d := openTestDB(t)
	for _, row := range []struct {
		title    string
		chatBorn int
		status   string
	}{
		{"mined proposal", 0, "proposed"},
		{"chat proposal", 1, "proposed"},
		{"chat approved", 1, "active"},
		{"chat rejected", 1, "rejected"},
		{"chat superseded", 1, "superseded"},
		{"chat reversed", 1, "reversed"},
	} {
		_, err := d.Exec(`INSERT INTO ideas (kind, title, chat_born, status) VALUES ('decision', ?, ?, ?)`, row.title, row.chatBorn, row.status)
		require.NoError(t, err)
	}
	rows, err := d.Query(`SELECT i.title FROM ideas i WHERE ` + KnowledgeVisibleIdeaCond("i") + ` ORDER BY i.id`)
	require.NoError(t, err)
	defer rows.Close()
	var titles []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		titles = append(titles, s)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, []string{"mined proposal", "chat approved", "chat superseded", "chat reversed"}, titles)
}
