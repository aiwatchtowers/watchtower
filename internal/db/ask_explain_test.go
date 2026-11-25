package db

import (
	"database/sql"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAskExplainWorkbenchID(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want int64
		ok   bool
	}{
		{"4:9", 4, true},
		{"12:345", 12, true},
		{"4", 0, false},
		{"x:9", 0, false},
		{"4:x", 0, false},
		{"0:9", 0, false},
		{"", 0, false},
		{"04:9", 0, false},
		{"4:09", 0, false},
		{"+4:9", 0, false},
		{"4:-9", 0, false},
	} {
		got, ok := AskExplainWorkbenchID(tc.in)
		assert.Equal(t, tc.ok, ok, tc.in)
		assert.Equal(t, tc.want, got, tc.in)
	}
}

// A queued follow-up saved after its workbench was deleted (the delete's
// transaction committed first) writes nothing: the two writers are serialised
// by the write lock, and whichever commits first, no draft of a deleted
// "Not clear?" chat is left (ask #1849, board #2383). Other surfaces' keys are
// untouched.
func TestQueuedDraftOfADeletedAskExplainChatIsNotSaved(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('Ask #5', ?, ?, 0, 0)`, AskExplainContextType, fmt.Sprintf("%d:5", pid))
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	key := fmt.Sprintf("owner_ask_explain.%d:5.%d", pid, conv)

	save := func(key string) {
		require.NoError(t, d.WithTx(func(tx *sql.Tx) error { return SaveQueuedDraftTx(tx, key, "and B?", 1) }))
	}
	// Saved before the delete: the delete takes it.
	save(key)
	require.NoError(t, d.DeleteWorkbench(pid))
	// Saved after the delete: nothing is written.
	save(key)
	save("track:3")

	var keys []string
	rows, err := d.Query(`SELECT surface_key FROM chat_queued_drafts ORDER BY surface_key`)
	require.NoError(t, err)
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var k string
		require.NoError(t, rows.Scan(&k))
		keys = append(keys, k)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, []string{"track:3"}, keys)
}
