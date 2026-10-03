package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00082_CreatesTheArtifactCommentsTable pins the shape the
// Desktop writes (projects POC phase 6): owner comments anchored on an AI
// Chat artifact's rendered text, keyed by (conversation, artifact key).
func TestMigration00082_CreatesTheArtifactCommentsTable(t *testing.T) {
	d := openTestDB(t)

	got := columnNames(t, d.DB, "chat_artifact_comments")
	for _, c := range []string{"id", "conversation_id", "artifact_key", "artifact_version", "body",
		"anchor_quote", "anchor_prefix", "anchor_suffix", "anchor_heading", "status", "created_at", "sent_at"} {
		assert.True(t, got[c], "chat_artifact_comments.%s missing", c)
	}
	var name string
	require.NoError(t, d.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?`,
		"idx_chat_artifact_comments_key").Scan(&name))
}

// TestMigration00082_ConstraintsHold: the status CHECK, a comment always has
// a quote and a body, a sent comment always has sent_at, and deleting the
// conversation deletes its comments.
func TestMigration00082_ConstraintsHold(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)

	insert := func(quote, body, status string, sentAt any) error {
		_, err := d.Exec(`INSERT INTO chat_artifact_comments
			(conversation_id, artifact_key, artifact_version, body, anchor_quote, status, created_at, sent_at)
			VALUES (?, 'plan', 1, ?, ?, ?, 0, ?)`, conv, body, quote, status, sentAt)
		return err
	}
	assert.Error(t, insert("q", "b", "draft", nil), "status CHECK")
	assert.Error(t, insert("", "b", "open", nil), "a comment is always anchored")
	assert.Error(t, insert("q", "", "open", nil), "a comment always has a body")
	assert.Error(t, insert("q", "b", "sent", nil), "a sent comment carries sent_at")
	require.NoError(t, insert("q", "b", "open", nil))
	require.NoError(t, insert("q", "b", "sent", 1.5))

	_, err = d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_artifact_comments`).Scan(&n))
	assert.Zero(t, n, "deleting the conversation deletes its artifact comments")
}

// TestMigration00082_DownDropsTheTable: other tests roll back through 00082,
// so its Down must be real.
func TestMigration00082_DownDropsTheTable(t *testing.T) {
	t.Parallel()
	d, err := Open(filepath.Join(t.TempDir(), "artifact-comments-cycle.db"))
	require.NoError(t, err)
	defer d.Close()

	// DownTo(81), not a bare Down: a later migration can move the tip past 00082.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 81))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%chat_artifact_comments%'`).Scan(&n))
	assert.Zero(t, n, "Down drops the table and its index")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	assert.True(t, columnNames(t, d.DB, "chat_artifact_comments")["anchor_quote"], "re-Up restores the table")
}
