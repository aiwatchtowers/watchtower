package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	tombLiveTS = "1700000100.000001"
	tombDelTS  = "1700000130.000001"
)

func seedTombstones(t *testing.T) *DB {
	t.Helper()
	d, err := Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	_, err = d.Exec(`INSERT INTO channels(id, name, type) VALUES ('1:C001','general','public')`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:C001", TS: tombLiveTS, UserID: "U001", Text: "live", ThreadTS: sql.NullString{String: "1700000100.000001", Valid: true}}))
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:C001", TS: tombDelTS, UserID: "U001", Text: "", IsDeleted: true, ThreadTS: sql.NullString{String: "1700000100.000001", Valid: true}}))
	return d
}

func TestMessageReaders_SkipTombstones(t *testing.T) {
	d := seedTombstones(t)

	msgs, err := d.GetMessages(MessageOpts{ChannelID: "1:C001"})
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, tombLiveTS, msgs[0].TS)

	msgs, err = d.GetMessages(MessageOpts{ExcludeDMs: true})
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, tombLiveTS, msgs[0].TS)

	replies, err := d.GetThreadReplies("1:C001", tombLiveTS)
	require.NoError(t, err)
	require.Len(t, replies, 1)
	assert.Equal(t, tombLiveTS, replies[0].TS)

	near, err := d.GetMessageNear("1:C001", 1700000130)
	require.NoError(t, err)
	require.NotNil(t, near)
	assert.Equal(t, tombLiveTS, near.TS)

	byTS, err := d.GetMessagesByTS("1:C001", []string{tombDelTS})
	require.NoError(t, err)
	assert.Empty(t, byTS)
}

// The digest's considered-mark is computed from this load, so tombstones stay.
func TestGetOldestMessagesByTimeRange_KeepsTombstones(t *testing.T) {
	d := seedTombstones(t)
	msgs, err := d.GetOldestMessagesByTimeRange("1:C001", 1700000000, 1700001000, 10)
	require.NoError(t, err)
	require.Len(t, msgs, 2)
	assert.True(t, msgs[1].IsDeleted)
}
