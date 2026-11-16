package chatstore

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The Desktop's embedded-chat tests check rows a Swift fake writes with the
// SQL these tests pin (Tests/Support/FakeEmbeddedPersist.swift); the rows
// themselves are Go's.

// TestEmbeddedTurn_BeginWritesOwnerAndPartialReply: one transaction writes
// the owner row and the reply's empty partial row.
func TestEmbeddedTurn_BeginWritesOwnerAndPartialReply(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	text := "q"
	et, err := s.BeginEmbedded(context.Background(), conv, &text, "t1", "claude")
	require.NoError(t, err)
	owner, ok := message(t, d, et.OwnerID)
	require.True(t, ok)
	assert.Equal(t, "user", owner.Role)
	assert.Equal(t, "q", owner.Text)
	reply, ok := message(t, d, et.MessageID)
	require.True(t, ok)
	assert.Equal(t, msgState{Role: "assistant", Text: "", Status: "partial", TurnID: "t1"}, reply)
}

// TestEmbeddedTurn_GoneConversationWritesNothing: a send into a deleted
// chat writes no row and says the chat is gone, so the run never reaches
// the provider (the Desktop's testASendThatCannotBeSavedSendsNothingAndKeepsTheText).
func TestEmbeddedTurn_GoneConversationWritesNothing(t *testing.T) {
	d, s, _ := newStore(t)
	text := "q"
	_, err := s.BeginEmbedded(context.Background(), 4242, &text, "t1", "")
	require.ErrorIs(t, err, ErrConversationGone)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages`).Scan(&n))
	assert.Zero(t, n)
}

// TestEmbeddedTurn_FlushCadence: the first delta is written at once, later
// ones at most once per FlushInterval; a stop keeps the partial text.
func TestEmbeddedTurn_FlushCadence(t *testing.T) {
	d, s, clock := newStore(t)
	conv := newConversation(t, d)
	text := "q"
	et, err := s.BeginEmbedded(context.Background(), conv, &text, "t1", "")
	require.NoError(t, err)
	row := func() msgState { m, _ := message(t, d, et.MessageID); return m }
	require.NoError(t, et.Apply(deltaEv("t1", "a")))
	assert.Equal(t, "a", row().Text, "the first delta at once")
	clock.advance(500 * time.Millisecond)
	require.NoError(t, et.Apply(deltaEv("t1", "b")))
	assert.Equal(t, "a", row().Text, "inside the flush interval")
	clock.advance(600 * time.Millisecond)
	require.NoError(t, et.Apply(deltaEv("t1", "c")))
	assert.Equal(t, "abc", row().Text)
	require.NoError(t, et.Finalize(StatusPartial, nil))
	assert.Equal(t, msgState{Role: "assistant", Text: "abc", Status: "partial", TurnID: "t1"}, row(),
		"a stopped run keeps its partial text")
}
