package db

import (
	"strconv"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00104_RemovesOrphanCodeQuestions: code questions of a
// workbench that no longer exists go with their messages; a live
// workbench's, a main-chat row and a malformed context id stay.
func TestMigration00104_RemovesOrphanCodeQuestions(t *testing.T) {
	t.Parallel()
	raw := rawDBAt(t, 103)
	res, err := raw.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')`)
	require.NoError(t, err)
	live, err := res.LastInsertId()
	require.NoError(t, err)

	conv := func(contextType any, contextID string) int64 {
		t.Helper()
		res, err := raw.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
			VALUES ('q', ?, ?, 0, 0)`, contextType, contextID)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		_, err = raw.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, 'user', 'q', 0)`, id)
		require.NoError(t, err)
		return id
	}
	gone := conv("code_question", "999:main.go:3")
	goneNoFile := conv("code_question", "999::0")
	kept := conv("code_question", strconv.FormatInt(live, 10)+":main.go:3")
	mainChat := conv(nil, "999:main.go:3")
	malformed := conv("code_question", "main.go")

	require.NoError(t, goose.Up(raw, "migrations"))

	count := func(q string, id int64) int {
		t.Helper()
		var n int
		require.NoError(t, raw.QueryRow(q, id).Scan(&n))
		return n
	}
	for _, id := range []int64{gone, goneNoFile} {
		assert.Zero(t, count(`SELECT COUNT(*) FROM chat_conversations WHERE id = ?`, id))
		assert.Zero(t, count(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`, id))
	}
	for _, id := range []int64{kept, mainChat, malformed} {
		assert.Equal(t, 1, count(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`, id))
	}
}
