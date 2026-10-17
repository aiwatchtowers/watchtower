package db

import (
	"database/sql"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// SlackAccountHasMessages scopes by the namespaced channel id: account 1
// must not see account 11's messages.
func TestSlackAccountHasMessages(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	has, err := db.SlackAccountHasMessages(1)
	require.NoError(t, err)
	assert.False(t, has)

	require.NoError(t, db.UpsertMessage(Message{ChannelID: "11:C1", TS: "1700000000.000001", UserID: "11:U1", Text: "x"}))
	has, err = db.SlackAccountHasMessages(1)
	require.NoError(t, err)
	assert.False(t, has, "account 11's message is not account 1's")

	require.NoError(t, db.UpsertMessage(Message{ChannelID: "1:C1", TS: "1700000000.000001", UserID: "1:U1", Text: "x"}))
	has, err = db.SlackAccountHasMessages(1)
	require.NoError(t, err)
	assert.True(t, has)
}

func TestUpsertMessage(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	msg := Message{
		ChannelID:  "C001",
		TS:         "1700000000.000001",
		UserID:     "U001",
		Text:       "Hello world",
		ReplyCount: 0,
	}
	err = db.UpsertMessage(msg)
	require.NoError(t, err)

	msgs, err := db.GetMessages(MessageOpts{ChannelID: "C001", Limit: 10})
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, "Hello world", msgs[0].Text)
	assert.Equal(t, "U001", msgs[0].UserID)
	assert.Equal(t, float64(1700000000), msgs[0].TSUnix)
}

func TestUpsertMessageUpdate(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	msg := Message{ChannelID: "C001", TS: "1700000000.000001", UserID: "U001", Text: "original"}
	require.NoError(t, db.UpsertMessage(msg))

	msg.Text = "edited"
	msg.IsEdited = true
	require.NoError(t, db.UpsertMessage(msg))

	msgs, err := db.GetMessages(MessageOpts{ChannelID: "C001", Limit: 10})
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, "edited", msgs[0].Text)
	assert.True(t, msgs[0].IsEdited)
}

func TestUpsertMessageWithThread(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	parent := Message{ChannelID: "C001", TS: "1700000000.000001", UserID: "U001", Text: "parent", ReplyCount: 2}
	require.NoError(t, db.UpsertMessage(parent))

	reply := Message{
		ChannelID: "C001",
		TS:        "1700000001.000001",
		UserID:    "U002",
		Text:      "reply",
		ThreadTS:  sql.NullString{String: "1700000000.000001", Valid: true},
	}
	require.NoError(t, db.UpsertMessage(reply))

	msgs, err := db.GetMessages(MessageOpts{ChannelID: "C001", Limit: 10})
	require.NoError(t, err)
	assert.Len(t, msgs, 2)
}

func TestGetMessages(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Insert messages across channels and users
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000001.000001", UserID: "U001", Text: "msg1"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000002.000001", UserID: "U002", Text: "msg2"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C002", TS: "1700000003.000001", UserID: "U001", Text: "msg3"}))

	// No filter - all messages, newest first
	msgs, err := db.GetMessages(MessageOpts{Limit: 10})
	require.NoError(t, err)
	assert.Len(t, msgs, 3)
	assert.Equal(t, "msg3", msgs[0].Text) // Newest first

	// Filter by channel
	msgs, err = db.GetMessages(MessageOpts{ChannelID: "C001", Limit: 10})
	require.NoError(t, err)
	assert.Len(t, msgs, 2)

	// Filter by user
	msgs, err = db.GetMessages(MessageOpts{UserID: "U001", Limit: 10})
	require.NoError(t, err)
	assert.Len(t, msgs, 2)

	// Filter by both
	msgs, err = db.GetMessages(MessageOpts{ChannelID: "C001", UserID: "U001", Limit: 10})
	require.NoError(t, err)
	assert.Len(t, msgs, 1)
	assert.Equal(t, "msg1", msgs[0].Text)
}

func TestGetMessagesDefaultLimit(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Insert more than 100 messages
	for i := range 110 {
		ts := fmt.Sprintf("17000%05d.000001", i)
		require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: ts, UserID: "U001", Text: "msg"}))
	}

	msgs, err := db.GetMessages(MessageOpts{ChannelID: "C001"})
	require.NoError(t, err)
	assert.Len(t, msgs, 100) // Default limit is 100
}

// TestGetOldestMessagesByTimeRange pins the two contracts that are
// load-bearing for the per-channel digest watermark: rows come back OLDEST first, and the limit therefore
// truncates at the NEWER end — the only end a later cycle's window can reach
// once the watermark has advanced past what was rendered.
func TestGetOldestMessagesByTimeRange(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000001.000001", UserID: "U001", Text: "early"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000500.000001", UserID: "U001", Text: "middle"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700001000.000001", UserID: "U001", Text: "late"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C002", TS: "1700000002.000001", UserID: "U001", Text: "other channel"}))

	msgs, err := db.GetOldestMessagesByTimeRange("C001", 1700000000, 1700002000, 10)
	require.NoError(t, err)
	require.Len(t, msgs, 3, "C002's message is inside the window but belongs to another channel")
	assert.Equal(t, []string{"early", "middle", "late"}, []string{msgs[0].Text, msgs[1].Text, msgs[2].Text},
		"oldest first — newest-first truncation would strand the older remainder")

	// The limit drops the NEWEST rows, leaving a remainder a later window reaches.
	msgs, err = db.GetOldestMessagesByTimeRange("C001", 1700000000, 1700002000, 2)
	require.NoError(t, err)
	require.Len(t, msgs, 2)
	assert.Equal(t, []string{"early", "middle"}, []string{msgs[0].Text, msgs[1].Text},
		"truncation must leave the newer remainder, never strand the older one")

	// Bounds are inclusive at both ends.
	msgs, err = db.GetOldestMessagesByTimeRange("C001", 1700000500, 1700001000, 10)
	require.NoError(t, err)
	require.Len(t, msgs, 2)
	assert.Equal(t, "middle", msgs[0].Text)
	assert.Equal(t, "late", msgs[1].Text)

	msgs, err = db.GetOldestMessagesByTimeRange("C001", 1700002000, 1700003000, 10)
	require.NoError(t, err)
	assert.Empty(t, msgs)
}

func TestGetMessagesChannelLimit(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000001.000001", UserID: "U001", Text: "old"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000002.000001", UserID: "U001", Text: "new"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C002", TS: "1700000003.000001", UserID: "U001", Text: "other"}))

	msgs, err := db.GetMessages(MessageOpts{ChannelID: "C001", Limit: 10})
	require.NoError(t, err)
	assert.Len(t, msgs, 2)
	// Newest first
	assert.Equal(t, "new", msgs[0].Text)
	assert.Equal(t, "old", msgs[1].Text)

	// Test limit
	msgs, err = db.GetMessages(MessageOpts{ChannelID: "C001", Limit: 1})
	require.NoError(t, err)
	assert.Len(t, msgs, 1)
	assert.Equal(t, "new", msgs[0].Text)
}

func TestGetThreadReplies(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	threadTS := "1700000000.000001"
	// Parent message
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: threadTS, UserID: "U001", Text: "parent", ReplyCount: 2}))
	// Replies
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000001.000001", UserID: "U002", Text: "reply1", ThreadTS: sql.NullString{String: threadTS, Valid: true}}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000002.000001", UserID: "U003", Text: "reply2", ThreadTS: sql.NullString{String: threadTS, Valid: true}}))
	// Unrelated message
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000003.000001", UserID: "U001", Text: "unrelated"}))

	msgs, err := db.GetThreadReplies("C001", threadTS)
	require.NoError(t, err)
	require.Len(t, msgs, 3)
	// Sorted ascending
	assert.Equal(t, "parent", msgs[0].Text)
	assert.Equal(t, "reply1", msgs[1].Text)
	assert.Equal(t, "reply2", msgs[2].Text)
}

func TestGetThreadRepliesEmpty(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	msgs, err := db.GetThreadReplies("C001", "9999999999.000001")
	require.NoError(t, err)
	assert.Empty(t, msgs)
}

func TestUpsertMessageUnicode(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	msg := Message{
		ChannelID: "C001",
		TS:        "1700000000.000001",
		UserID:    "U001",
		Text:      "Hello 世界! 🚀 café naïve Ñoño デプロイメント",
	}
	require.NoError(t, db.UpsertMessage(msg))

	msgs, err := db.GetMessages(MessageOpts{ChannelID: "C001", Limit: 10})
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, msg.Text, msgs[0].Text)
}

func TestUpsertMessageEmptyText(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	msg := Message{
		ChannelID: "C001",
		TS:        "1700000000.000001",
		UserID:    "U001",
		Text:      "",
	}
	require.NoError(t, db.UpsertMessage(msg))

	msgs, err := db.GetMessages(MessageOpts{ChannelID: "C001", Limit: 10})
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, "", msgs[0].Text)
}

func TestGetMessageNearEdgeCases(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Insert two messages close together
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000000.000001", UserID: "U001", Text: "first"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000030.000001", UserID: "U001", Text: "second"}))

	// Closest to first message
	msg, err := db.GetMessageNear("C001", 1700000010)
	require.NoError(t, err)
	require.NotNil(t, msg)
	assert.Equal(t, "first", msg.Text)

	// Closest to second message
	msg, err = db.GetMessageNear("C001", 1700000025)
	require.NoError(t, err)
	require.NotNil(t, msg)
	assert.Equal(t, "second", msg.Text)

	// Outside tolerance (>60s from any message)
	msg, err = db.GetMessageNear("C001", 1700000200)
	require.NoError(t, err)
	assert.Nil(t, msg)
}
