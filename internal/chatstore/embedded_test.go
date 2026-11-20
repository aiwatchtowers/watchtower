package chatstore

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"watchtower/internal/chat"

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
	conv := newEmbeddedConversation(t, d)
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

// newEmbeddedConversation is a target's embedded chat (context_type set):
// BeginEmbedded refuses a main chat.
func newEmbeddedConversation(t *testing.T, d interface {
	Exec(string, ...any) (sql.Result, error)
}) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('', 'target', '7', 1, 1)`)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// TestEmbeddedTurn_MainChatIsRefusedAndWritesNothing: `ai query --persist`
// never writes a main chat (context_type NULL): its rows are the chat
// engine's, under its turn lock. The start is refused with ErrNotEmbedded
// and no row is written.
func TestEmbeddedTurn_MainChatIsRefusedAndWritesNothing(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	text := "q"
	_, err := s.BeginEmbedded(context.Background(), conv, &text, "t1", "")
	require.ErrorIs(t, err, ErrNotEmbedded)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`, conv).Scan(&n))
	assert.Zero(t, n)
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
	conv := newEmbeddedConversation(t, d)
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

// TestEmbeddedTurn_QuotaErrorKeepsStreamedTextAsPartial: a turn error ends
// the turn with its code; a quota stop with text keeps it as partial, one
// with none is an error — and nothing after the error is written.
func TestEmbeddedTurn_QuotaErrorKeepsStreamedTextAsPartial(t *testing.T) {
	for _, text := range []string{"", "Partial before quota"} {
		d, s, _ := newStore(t)
		conv := newEmbeddedConversation(t, d)
		owner := "q"
		et, err := s.BeginEmbedded(context.Background(), conv, &owner, "t1", "")
		require.NoError(t, err)
		if text != "" {
			require.NoError(t, et.Apply(deltaEv("t1", text)))
		}
		e := ev(chat.EventError, "t1")
		e.Code, e.Reason, e.Message = chat.CodeRateLimit, "quota_exhausted", "Quota reached"
		require.NoError(t, et.Apply(e))
		require.True(t, et.Done())
		late := ev(chat.EventSessionReady, "t1")
		late.Provider, late.Model = "codex", "after-the-error"
		require.NoError(t, et.Apply(late))
		want := "error"
		if text != "" {
			want = "partial"
		}
		m, _ := message(t, d, et.MessageID)
		assert.Equal(t, msgState{Role: "assistant", Text: text, Status: want, TurnID: "t1",
			ErrorCode: sql.NullString{String: "quota_exhausted", Valid: true}}, m)
		var model sql.NullString
		require.NoError(t, d.QueryRow(`SELECT model FROM chat_messages WHERE id = ?`, et.MessageID).Scan(&model))
		assert.False(t, model.Valid, "nothing is written after the turn's end")
	}
}

// The Desktop's EmbeddedChatStoreTests checked these on the Swift database
// store before its writes moved here (#1170 Task 18).

// TestEmbeddedTurn_ReplyRecordsItsProvider: the reply row names the run's
// provider (the error card's sign-in hint reads it).
func TestEmbeddedTurn_ReplyRecordsItsProvider(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newEmbeddedConversation(t, d)
	text := "hello"
	et, err := s.BeginEmbedded(context.Background(), conv, &text, "t1", "codex")
	require.NoError(t, err)
	var provider sql.NullString
	require.NoError(t, d.QueryRow(`SELECT provider FROM chat_messages WHERE id = ?`, et.MessageID).Scan(&provider))
	assert.Equal(t, "codex", provider.String)
}

// TestEmbeddedTurn_FollowUpWritesNoOwnerRow: a hidden prompt (nil owner
// text) writes the reply alone.
func TestEmbeddedTurn_FollowUpWritesNoOwnerRow(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newEmbeddedConversation(t, d)
	et, err := s.BeginEmbedded(context.Background(), conv, nil, "t1", "")
	require.NoError(t, err)
	assert.Zero(t, et.OwnerID)
	var roles []string
	rows, err := d.Query(`SELECT role FROM chat_messages WHERE conversation_id = ? ORDER BY id`, conv)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var r string
		require.NoError(t, rows.Scan(&r))
		roles = append(roles, r)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, []string{"assistant"}, roles)
}

// TestEmbeddedTurn_ErrorEndKeepsTheTextAndItsCode: a turn error ends the
// reply with its text, status, code and message.
func TestEmbeddedTurn_ErrorEndKeepsTheTextAndItsCode(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newEmbeddedConversation(t, d)
	text := "q"
	et, err := s.BeginEmbedded(context.Background(), conv, &text, "t", "")
	require.NoError(t, err)
	require.NoError(t, et.Apply(deltaEv("t", "half")))
	m, _ := message(t, d, et.MessageID)
	assert.Equal(t, "half", m.Text)
	require.NoError(t, et.Apply(deltaEv("t", " and more")))
	e := ev(chat.EventError, "t")
	e.Code, e.Message = chat.CodeAuth, "not logged in"
	require.NoError(t, et.Apply(e))
	var msg sql.NullString
	require.NoError(t, d.QueryRow(`SELECT error_message FROM chat_messages WHERE id = ?`, et.MessageID).Scan(&msg))
	m, _ = message(t, d, et.MessageID)
	assert.Equal(t, msgState{Role: "assistant", Text: "half and more", Status: "error", TurnID: "t",
		ErrorCode: sql.NullString{String: "auth", Valid: true}}, m)
	assert.Equal(t, "not logged in", msg.String)
}

// TestEmbeddedTurn_RowsKeepTheTreeColumnsAtTheirDefaults: an embedded row
// leaves the main chat's tree columns at their defaults, so readers see a
// linear thread.
func TestEmbeddedTurn_RowsKeepTheTreeColumnsAtTheirDefaults(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newEmbeddedConversation(t, d)
	text := "q"
	et, err := s.BeginEmbedded(context.Background(), conv, &text, "t", "")
	require.NoError(t, err)
	require.NoError(t, et.Apply(deltaEv("t", "a")))
	require.NoError(t, et.Finalize(StatusComplete, nil))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?
		AND (parent_id IS NOT NULL OR model IS NOT NULL OR tokens_in IS NOT NULL)`, conv).Scan(&n))
	assert.Zero(t, n)
	m, _ := message(t, d, et.MessageID)
	assert.Equal(t, "complete", m.Status)
	assert.False(t, m.ErrorCode.Valid)
}

// TestEmbeddedTurn_OnlyACompletedReplyTouchesTheConversation: a failed
// reply is not activity; a completed one moves updated_at.
func TestEmbeddedTurn_OnlyACompletedReplyTouchesTheConversation(t *testing.T) {
	d, s, clock := newStore(t)
	conv := newEmbeddedConversation(t, d)
	_, err := d.Exec(`UPDATE chat_conversations SET updated_at = 1 WHERE id = ?`, conv)
	require.NoError(t, err)
	updatedAt := func() float64 {
		var at float64
		require.NoError(t, d.QueryRow(`SELECT updated_at FROM chat_conversations WHERE id = ?`, conv).Scan(&at))
		return at
	}
	text := "q"
	failed, err := s.BeginEmbedded(context.Background(), conv, &text, "t", "")
	require.NoError(t, err)
	require.NoError(t, failed.Finalize(StatusError, &Failure{Code: chat.CodeInternal, Message: "x"}))
	assert.InDelta(t, 1, updatedAt(), 0, "a failed reply is not activity")
	clock.advance(time.Second)
	done, err := s.BeginEmbedded(context.Background(), conv, &text, "t2", "")
	require.NoError(t, err)
	require.NoError(t, done.Finalize(StatusComplete, nil))
	assert.Greater(t, updatedAt(), 1.0)
}

// TestEmbeddedTurn_DeletedConversationMidTurnIsGone: the chat deleted while
// its turn runs: the next write says it is gone.
func TestEmbeddedTurn_DeletedConversationMidTurnIsGone(t *testing.T) {
	d, s, clock := newStore(t)
	conv := newEmbeddedConversation(t, d)
	text := "q"
	et, err := s.BeginEmbedded(context.Background(), conv, &text, "t", "")
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)
	clock.advance(2 * time.Second)
	require.ErrorIs(t, et.Apply(deltaEv("t", "x")), ErrConversationGone)
	_, err = s.BeginEmbedded(context.Background(), conv, &text, "t2", "")
	require.ErrorIs(t, err, ErrConversationGone)
}
