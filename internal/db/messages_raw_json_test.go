package db

import (
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func rawJSONOf(t *testing.T, db *DB, channelID, ts string) string {
	t.Helper()
	var raw string
	require.NoError(t, db.QueryRow(`SELECT raw_json FROM messages WHERE channel_id = ? AND ts = ?`, channelID, ts).Scan(&raw))
	return raw
}

func TestMessagesRawJSONStaysEmpty(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1700000001.000001", UserID: "U1", Text: "one"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1700000001.000001", UserID: "U1", Text: "one edited"}))
	assert.Equal(t, "{}", rawJSONOf(t, db, "C1", "1700000001.000001"))

	tx, err := db.Begin()
	require.NoError(t, err)
	_, err = db.UpsertMessageBatch(tx, []Message{{ChannelID: "C1", TS: "1700000002.000001", UserID: "U1", Text: "two"}})
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	assert.Equal(t, "{}", rawJSONOf(t, db, "C1", "1700000002.000001"))
}

func TestMigration00130_ClearsMessagesRawJSON(t *testing.T) {
	raw := rawDBAt(t, 129)
	_, err := raw.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, raw_json) VALUES
		('C1', '1700000001.000001', 'U1', 'full', '{"ts":"1700000001.000001","blocks":[1]}'),
		('C1', '1700000002.000001', 'U1', 'empty', '{}')`)
	require.NoError(t, err)

	require.NoError(t, goose.UpTo(raw, "migrations", 130))

	var n int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM messages WHERE raw_json != '{}'`).Scan(&n))
	assert.Zero(t, n)
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n))
	assert.Equal(t, 2, n, "rows survive")
	for ts, want := range map[string]string{"1700000001.000001": "full", "1700000002.000001": "empty"} {
		var text string
		require.NoError(t, raw.QueryRow(`SELECT text FROM messages WHERE channel_id = 'C1' AND ts = ?`, ts).Scan(&text))
		assert.Equal(t, want, text, "text survives unchanged")
	}
}
