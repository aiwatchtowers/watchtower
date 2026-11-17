package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00194_ClientKeyUniquePerConversation: chat_messages.client_key
// is unique per conversation only where it is set — rows without a key never
// clash, the same key twice in one conversation is refused, and the same key
// in two conversations is allowed. Down drops the column and its index.
func TestMigration00194_ClientKeyUniquePerConversation(t *testing.T) {
	d := openTestDB(t)
	conv := func() int64 {
		res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	insert := func(c int64, key any) error {
		_, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, client_key)
			VALUES (?, 'user', 'hi', 1, ?)`, c, key)
		return err
	}
	a, b := conv(), conv()
	require.NoError(t, insert(a, nil))
	require.NoError(t, insert(a, nil), "two rows without a key")
	require.NoError(t, insert(a, "k-1"))
	err := insert(a, "k-1")
	require.Error(t, err, "the same key twice in one conversation")
	assert.Contains(t, err.Error(), "UNIQUE constraint failed: chat_messages.conversation_id, chat_messages.client_key")
	require.NoError(t, insert(b, "k-1"), "the same key in another conversation")

	require.NoError(t, gooseDownTo(d.DB, "migrations", 191))
	assert.Zero(t, countWhere(t, d, `SELECT COUNT(*) FROM pragma_table_info('chat_messages') WHERE name = 'client_key'`))
	assert.Zero(t, countWhere(t, d, `SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_chat_messages_client_key'`))
}
