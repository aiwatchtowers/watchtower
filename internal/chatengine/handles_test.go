package chatengine

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestChatengine_OwnHandleNotBlockedBySyncConn: the daemon's handle is one
// connection; while a sync holds it — in a write transaction, then in a long
// read — the engine on OpenHandles' handles still reads a feed and the list
// and starts a turn.
func TestChatengine_OwnHandleNotBlockedBySyncConn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	daemon, err := db.Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = daemon.Close() })
	conv := newConversation(t, daemon)

	write, read, err := OpenHandles(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = write.Close(); _ = read.Close() })
	assert.Equal(t, readPool, read.Stats().MaxOpenConnections)
	assert.Equal(t, 1, write.Stats().MaxOpenConnections)
	f := &fakeStarter{}
	e := New(Config{Exe: "/opt/watchtower", DBPath: path, Dir: t.TempDir(), DB: write, Read: read, Start: f.start})
	t.Cleanup(func() { _ = e.Close(context.Background()) })
	require.NoError(t, e.Start(context.Background()))

	// A sync's write transaction holds the daemon's only connection and the
	// write lock: reads go on (WAL).
	tx, err := daemon.Begin()
	require.NoError(t, err)
	_, err = tx.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('sync', 2, 2)`)
	require.NoError(t, err)
	_, err = e.Feed(context.Background(), conv, 0)
	require.NoError(t, err)
	l, err := e.List(context.Background())
	require.NoError(t, err)
	assert.Len(t, l.Conversations, 1, "the sync's uncommitted row is not seen")
	require.NoError(t, tx.Commit())

	// A long read holds the daemon's connection: a turn still starts.
	rtx, err := daemon.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	require.NoError(t, err)
	var n int
	require.NoError(t, rtx.QueryRow(`SELECT COUNT(*) FROM chat_messages`).Scan(&n))
	st, err := e.Turn(context.Background(), turnReq(conv, "hello", ""))
	require.NoError(t, err)
	feed, err := e.Feed(context.Background(), conv, 0)
	require.NoError(t, err)
	require.NotEmpty(t, feed.Messages)
	assert.Equal(t, st.UserMessageID, feed.Messages[0].ID)
	require.NoError(t, rtx.Rollback())
}

// OpenHandles never creates a database.
func TestOpenHandles_MissingFileFails(t *testing.T) {
	_, _, err := OpenHandles(filepath.Join(t.TempDir(), "none.db"))
	assert.Error(t, err)
}
