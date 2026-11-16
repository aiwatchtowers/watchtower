package chatstore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/db"
)

func newConversation(t *testing.T, d *db.DB) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func newStore(t *testing.T, opts ...Option) (*db.DB, *Store, *fakeClock) {
	t.Helper()
	d := openDB(t)
	clock := newClock()
	return d, New(d, db.ChatLeaseHub, "hub-1", append([]Option{WithClock(clock.now)}, opts...)...), clock
}

type msgState struct {
	Role, Text, Status, TurnID string
	ErrorCode                  sql.NullString
}

func message(t *testing.T, d *db.DB, id int64) (msgState, bool) {
	t.Helper()
	var m msgState
	err := d.QueryRow(`SELECT role, text, status, turn_id, error_code FROM chat_messages WHERE id = ?`, id).
		Scan(&m.Role, &m.Text, &m.Status, &m.TurnID, &m.ErrorCode)
	if err == sql.ErrNoRows {
		return m, false
	}
	require.NoError(t, err)
	return m, true
}

func send(t *testing.T, s *Store, conv int64, text string) Started {
	t.Helper()
	st, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeSend, Text: text, TurnID: "turn-" + text})
	require.NoError(t, err)
	return st
}

func ev(typ, turn string) chat.Event { return chat.Event{Type: typ, TurnID: turn} }

func deltaEv(turn, text string) chat.Event {
	e := ev(chat.EventTextDelta, turn)
	e.Text = text
	return e
}

func toolStart(turn, id, name string) chat.Event {
	e := ev(chat.EventToolStart, turn)
	e.ID, e.Name = id, name
	return e
}

// TestChat01Go_OwnerRowBeforeTurn: after Start the owner's text is on disk
// and the reply row exists, empty and partial, both carrying the lease's
// turn id (BEHAVIOR CHAT-01 — see docs/inventory/chat.md).
func TestChat01Go_OwnerRowBeforeTurn(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "What changed?")
	owner, ok := message(t, d, st.UserMessageID)
	require.True(t, ok)
	assert.Equal(t, msgState{Role: "user", Text: "What changed?", Status: "complete", TurnID: st.TurnID}, owner)
	reply, ok := message(t, d, st.AssistantMessageID)
	require.True(t, ok)
	assert.Equal(t, msgState{Role: "assistant", Text: "", Status: "partial", TurnID: st.TurnID}, reply)
	lease, err := d.GetChatLease(conv)
	require.NoError(t, err)
	require.NotNil(t, lease)
	assert.Equal(t, st.TurnID, lease.TurnID, "the Mac matches the lease's turn id on the rows")
	assert.Equal(t, db.ChatLeaseHub, lease.Owner)
	assert.Equal(t, "hub-1", lease.OwnerID)

	st2, err := s.Start(context.Background(), StartRequest{ConversationID: newConversation(t, d), Mode: ModeSend, Text: "x"})
	require.NoError(t, err)
	assert.Regexp(t, `^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$`, st2.TurnID, "a UUID like the Mac's")
}

// TestChat02Go_StepPersistedOnStart: a tool_start is on disk at once, with
// no flush (BEHAVIOR CHAT-02 — see docs/inventory/chat.md).
func TestChat02Go_StepPersistedOnStart(t *testing.T) {
	d, s, _ := newStore(t)
	st := send(t, s, newConversation(t, d), "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "call-1", "search_knowledge")))
	var name string
	var ended sql.NullFloat64
	require.NoError(t, d.QueryRow(`SELECT name, ended_at FROM chat_turn_steps WHERE message_id = ? AND tool_id = 'call-1'`,
		st.AssistantMessageID).Scan(&name, &ended))
	assert.Equal(t, "search_knowledge", name)
	assert.False(t, ended.Valid)
	require.Len(t, turn.Steps(), 1)
	assert.Equal(t, StepRunning, turn.Steps()[0].State)
}

// TestTurn_FlushCadence: the first delta is written at once, later ones at
// most once per FlushInterval of the injected clock.
func TestTurn_FlushCadence(t *testing.T) {
	d, s, clock := newStore(t)
	st := send(t, s, newConversation(t, d), "hi")
	turn := s.Turn(st)
	text := func() string { m, _ := message(t, d, st.AssistantMessageID); return m.Text }
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "Hel")))
	assert.Equal(t, "Hel", text())
	clock.advance(900 * time.Millisecond)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "lo")))
	assert.Equal(t, "Hel", text(), "inside the flush interval")
	assert.Equal(t, "Hello", turn.Text(), "the live view has it all")
	clock.advance(100 * time.Millisecond)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "!")))
	assert.Equal(t, "Hello!", text())
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "?")))
	require.NoError(t, turn.Flush())
	assert.Equal(t, "Hello!?", text(), "an explicit flush writes now")
}

// TestChatstore_StopKeepsPartial: a Stop (the cancel watchdog's finalize)
// keeps everything streamed as partial, with no error, and frees the lease.
func TestChatstore_StopKeepsPartial(t *testing.T) {
	d, s, clock := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "Half")))
	clock.advance(200 * time.Millisecond)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, " way")))
	require.NoError(t, turn.Finalize(StatusPartial, nil))
	m, _ := message(t, d, st.AssistantMessageID)
	assert.Equal(t, msgState{Role: "assistant", Text: "Half way", Status: "partial", TurnID: st.TurnID}, m)
	lease, err := d.GetChatLease(conv)
	require.NoError(t, err)
	assert.Nil(t, lease)
	done, status := turn.Done()
	assert.True(t, done)
	assert.Equal(t, StatusPartial, status)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "late")), "events after the end are ignored")
	require.NoError(t, turn.Finalize(StatusComplete, nil), "a second finalize is a no-op")
	m, _ = message(t, d, st.AssistantMessageID)
	assert.Equal(t, "partial", m.Status)
}

// TestChatstore_ProcessDeathFinalizesPartial: the session died mid-turn —
// the text streamed so far stays as partial with session_lost (the twin of
// the Swift testChat01PartialTextSurvivesProcessDeath…).
func TestChatstore_ProcessDeathFinalizesPartial(t *testing.T) {
	d, s, clock := newStore(t)
	st := send(t, s, newConversation(t, d), "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "Partial ")))
	clock.advance(1500 * time.Millisecond)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "answer")))
	m, _ := message(t, d, st.AssistantMessageID)
	require.Equal(t, "Partial answer", m.Text, "flushed before the death")
	require.NoError(t, turn.Finalize(StatusPartial, &Failure{Code: chat.CodeSessionLost, Message: "the session ended"}))
	m, _ = message(t, d, st.AssistantMessageID)
	assert.Equal(t, "Partial answer", m.Text)
	assert.Equal(t, "partial", m.Status)
	assert.Equal(t, sql.NullString{String: "session_lost", Valid: true}, m.ErrorCode)
}

// TestChatstore_ConversationDeletedMidTurnStopsCleanly: a delete between a
// step and the end makes the next writes refuse with ErrConversationGone and
// leaves no row of that conversation anywhere.
func TestChatstore_ConversationDeletedMidTurnStopsCleanly(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(toolStart(st.TurnID, "call-1", "search_knowledge")))
	_, err := d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)

	assert.ErrorIs(t, turn.Apply(toolStart(st.TurnID, "call-2", "search_knowledge")), ErrConversationGone)
	assert.ErrorIs(t, turn.Apply(deltaEv(st.TurnID, ":::artifact key=\"x\" kind=\"document\" title=\"X\"\nbody\n:::")), ErrConversationGone)
	assert.ErrorIs(t, turn.Finalize(StatusComplete, nil), ErrConversationGone)

	// A fresh turn of the deleted chat (no state yet) finds it gone too.
	fresh := s.Turn(st)
	assert.ErrorIs(t, fresh.Apply(deltaEv(st.TurnID, "x")), ErrConversationGone)
	assert.ErrorIs(t, s.Turn(st).Finalize(StatusComplete, nil), ErrConversationGone)

	for _, q := range []string{
		`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`,
		`SELECT COUNT(*) FROM chat_turn_steps WHERE message_id IN (?, ?)`,
		`SELECT COUNT(*) FROM chat_artifacts WHERE conversation_id = ?`,
		`SELECT COUNT(*) FROM chat_turn_leases WHERE conversation_id = ?`,
	} {
		var n int
		args := []any{conv}
		if q == `SELECT COUNT(*) FROM chat_turn_steps WHERE message_id IN (?, ?)` {
			args = []any{st.UserMessageID, st.AssistantMessageID}
		}
		require.NoError(t, d.QueryRow(q, args...).Scan(&n))
		assert.Zero(t, n, q)
	}
	_, err = s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeSend, Text: "again"})
	assert.ErrorIs(t, err, ErrConversationGone)
}

// TestChatstore_ArchiveMidTurnFinishes: archiving only sets archived_at; the
// turn ends and is written normally.
func TestChatstore_ArchiveMidTurnFinishes(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "Answer")))
	_, err := d.Exec(`UPDATE chat_conversations SET archived_at = 5 WHERE id = ?`, conv)
	require.NoError(t, err)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, " done")))
	done := ev(chat.EventTurnDone, st.TurnID)
	done.Status = chat.StatusComplete
	require.NoError(t, turn.Apply(done))
	m, _ := message(t, d, st.AssistantMessageID)
	assert.Equal(t, msgState{Role: "assistant", Text: "Answer done", Status: "complete", TurnID: st.TurnID}, m)
}

// TestChatstore_BranchSelectMidTurn: a branch select during a turn is never
// refused; the turn finishes by message id and the leaf stays where the
// owner put it (D17).
func TestChatstore_BranchSelectMidTurn(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	first := send(t, s, conv, "one")
	t1 := s.Turn(first)
	done := ev(chat.EventTurnDone, first.TurnID)
	done.Status = chat.StatusComplete
	require.NoError(t, t1.Apply(deltaEv(first.TurnID, "A1")))
	require.NoError(t, t1.Apply(done))

	st, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeRegenerate, MessageID: first.AssistantMessageID, TurnID: "regen"})
	require.NoError(t, err)
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(deltaEv("regen", "A2")))
	require.NoError(t, s.SelectBranch(context.Background(), first.AssistantMessageID))
	regenDone := ev(chat.EventTurnDone, "regen")
	regenDone.Status = chat.StatusComplete
	require.NoError(t, turn.Apply(regenDone))

	m, _ := message(t, d, st.AssistantMessageID)
	assert.Equal(t, "A2", m.Text)
	assert.Equal(t, "complete", m.Status)
	var leaf int64
	require.NoError(t, d.QueryRow(`SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?`, conv).Scan(&leaf))
	assert.Equal(t, first.AssistantMessageID, leaf)

	assert.ErrorIs(t, s.SelectBranch(context.Background(), 999999), ErrNotFound)
}

// TestSelectBranch_NewestLeafUnderSibling: selecting a sibling lands on the
// newest leaf of its subtree (ChatTree.newestLeaf).
func TestSelectBranch_NewestLeafUnderSibling(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	ins := func(parent any, role string) int64 {
		res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at) VALUES (?, ?, ?, '', 1)`, conv, parent, role)
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		return id
	}
	u1 := ins(nil, "user")
	a1 := ins(u1, "assistant")
	u2 := ins(a1, "user")
	a2 := ins(u2, "assistant")
	u2b := ins(a1, "user") // an edit of u2
	a2b := ins(u2b, "assistant")
	require.NoError(t, s.SelectBranch(context.Background(), u2))
	var leaf int64
	require.NoError(t, d.QueryRow(`SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?`, conv).Scan(&leaf))
	assert.Equal(t, a2, leaf)
	require.NoError(t, s.SelectBranch(context.Background(), u1))
	require.NoError(t, d.QueryRow(`SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?`, conv).Scan(&leaf))
	assert.Equal(t, a2b, leaf)
}

// TestStart_BusyWritesNothing: another owner's live lease refuses the start
// with ErrBusy and no row is written; a stale lease is taken over.
func TestStart_BusyWritesNothing(t *testing.T) {
	d, s, clock := newStore(t)
	conv := newConversation(t, d)
	now := clock.now().UnixMilli()
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		ok, err := db.ClaimChatLeaseTx(tx, db.ChatLease{ConversationID: conv, Owner: db.ChatLeaseDesktop, OwnerID: "mac",
			TurnID: "mac-turn", StartedAtMS: now, HeartbeatAtMS: now}, now)
		require.True(t, ok)
		return err
	}))
	_, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeSend, Text: "hello"})
	assert.ErrorIs(t, err, ErrBusy)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`, conv).Scan(&n))
	assert.Zero(t, n)
	var title string
	require.NoError(t, d.QueryRow(`SELECT title FROM chat_conversations WHERE id = ?`, conv).Scan(&title))
	assert.Empty(t, title, "no prefix title either")

	clock.advance(time.Duration(db.ChatLeaseStaleMS+1) * time.Millisecond)
	st := send(t, s, conv, "hello")
	lease, err := d.GetChatLease(conv)
	require.NoError(t, err)
	assert.Equal(t, st.TurnID, lease.TurnID)
}

// TestStart_Refusals: the rules the Mac's composer and menus enforce.
func TestStart_Refusals(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	first := send(t, s, conv, "q")
	turn := s.Turn(first)
	e := ev(chat.EventError, first.TurnID)
	e.Code, e.Reason = chat.CodeRateLimit, "quota_exhausted"
	require.NoError(t, turn.Apply(e))
	other := newConversation(t, d)
	res, err := d.Exec(`INSERT INTO chat_attachments (conversation_id, name, mime, size, path, sha256, created_at) VALUES (?, 'a', 'text/plain', 1, '/a', 's', 1)`, other)
	require.NoError(t, err)
	foreign, _ := res.LastInsertId()
	discuss, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at) VALUES ('', 'target', '1', 1, 1)`)
	require.NoError(t, err)
	discussID, _ := discuss.LastInsertId()

	for name, tc := range map[string]struct {
		r    StartRequest
		want error
	}{
		"empty send":               {StartRequest{ConversationID: conv, Mode: ModeSend, Text: "  "}, ErrInvalid},
		"unknown mode":             {StartRequest{ConversationID: conv, Mode: "retry", Text: "x"}, ErrInvalid},
		"regenerate an owner row":  {StartRequest{ConversationID: conv, Mode: ModeRegenerate, MessageID: first.UserMessageID}, ErrInvalid},
		"regenerate a quota reply": {StartRequest{ConversationID: conv, Mode: ModeRegenerate, MessageID: first.AssistantMessageID}, ErrInvalid},
		"edit an answer":           {StartRequest{ConversationID: conv, Mode: ModeEdit, MessageID: first.AssistantMessageID, Text: "x"}, ErrInvalid},
		"edit to nothing":          {StartRequest{ConversationID: conv, Mode: ModeEdit, MessageID: first.UserMessageID, Text: " "}, ErrInvalid},
		"edit a missing message":   {StartRequest{ConversationID: conv, Mode: ModeEdit, MessageID: 99999, Text: "x"}, ErrNotFound},
		"another chat's file":      {StartRequest{ConversationID: conv, Mode: ModeSend, Text: "x", AttachmentIDs: []int64{foreign}}, ErrAttachmentMissing},
		"a missing file":           {StartRequest{ConversationID: conv, Mode: ModeSend, Text: "x", AttachmentIDs: []int64{424242}}, ErrAttachmentMissing},
		"an unknown provider":      {StartRequest{ConversationID: conv, Mode: ModeSend, Text: "x", Routing: &Routing{Provider: "gpt"}}, ErrInvalid},
		"a Discuss chat":           {StartRequest{ConversationID: discussID, Mode: ModeSend, Text: "x"}, ErrInvalid},
		"a missing conversation":   {StartRequest{ConversationID: 77777, Mode: ModeSend, Text: "x"}, ErrConversationGone},
	} {
		t.Run(name, func(t *testing.T) {
			var before int
			require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages`).Scan(&before))
			_, err := s.Start(context.Background(), tc.r)
			assert.ErrorIs(t, err, tc.want)
			var after int
			require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages`).Scan(&after))
			assert.Equal(t, before, after, "a refused start writes nothing")
		})
	}
}

// TestMarkRead_NeverBackwards: read_at follows the last complete answer on
// the active branch, never moves back, and leaves updated_at alone.
func TestMarkRead_NeverBackwards(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	ins := func(parent any, role, status string, created float64) int64 {
		res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, status, created_at) VALUES (?, ?, ?, '', ?, ?)`,
			conv, parent, role, status, created)
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		return id
	}
	readAt := func() sql.NullFloat64 {
		var r sql.NullFloat64
		require.NoError(t, d.QueryRow(`SELECT read_at FROM chat_conversations WHERE id = ?`, conv).Scan(&r))
		return r
	}
	require.NoError(t, s.MarkRead(context.Background(), conv, 0))
	assert.False(t, readAt().Valid, "no complete answer: nothing changes")

	u1 := ins(nil, "user", "complete", 10)
	a1 := ins(u1, "assistant", "complete", 20)
	u2 := ins(a1, "user", "complete", 30)
	a2 := ins(u2, "assistant", "complete", 40)
	a2b := ins(u2, "assistant", "partial", 50)
	_, err := d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, a2b, conv)
	require.NoError(t, err)

	require.NoError(t, s.MarkRead(context.Background(), conv, 0))
	assert.InDelta(t, 20, readAt().Float64, 0.001, "the partial answer on the branch is not read; a2 is another branch")

	_, err = d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, a2, conv)
	require.NoError(t, err)
	require.NoError(t, s.MarkRead(context.Background(), conv, a1))
	assert.InDelta(t, 20, readAt().Float64, 0.001, "bounded by what the phone showed")
	require.NoError(t, s.MarkRead(context.Background(), conv, 0))
	assert.InDelta(t, 40, readAt().Float64, 0.001)

	_, err = d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, a1, conv)
	require.NoError(t, err)
	require.NoError(t, s.MarkRead(context.Background(), conv, 0))
	assert.InDelta(t, 40, readAt().Float64, 0.001, "never backwards")
	var updated float64
	require.NoError(t, d.QueryRow(`SELECT updated_at FROM chat_conversations WHERE id = ?`, conv).Scan(&updated))
	assert.InDelta(t, 1, updated, 0.001, "reading is not activity")
}

// TestPrefix_RememberAndIdeaRun: a remember prefix adds the chat
// instruction line, a knowledge prefix writes a chat-born idea.
func TestPrefix_RememberAndIdeaRun(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "remember: answer in   short bullets")
	require.NoError(t, st.PrefixErr)
	assert.Equal(t, string(db.RememberAdded), st.RememberOutcome)
	assert.NotZero(t, st.RememberLineID, "the added line's id (the Mac's Undo)")
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Contains(t, got.Chat, "answer in short bullets")

	st = send(t, s, newConversation(t, d), "решили: ship on Monday\nQA signed off")
	require.NoError(t, st.PrefixErr)
	require.NotZero(t, st.IdeaID)
	assert.Equal(t, "decision", st.IdeaKind)
	var kind, essence string
	var chatBorn int
	require.NoError(t, d.QueryRow(`SELECT kind, essence, chat_born FROM ideas WHERE id = ?`, st.IdeaID).Scan(&kind, &essence, &chatBorn))
	assert.Equal(t, []any{"decision", "ship on Monday\nQA signed off", 1}, []any{kind, essence, chatBorn})

	st = send(t, s, newConversation(t, d), "remember:")
	assert.Equal(t, RememberEmpty, st.RememberOutcome)
	st = send(t, s, newConversation(t, d), "plain question")
	assert.Empty(t, st.RememberOutcome)
	assert.Zero(t, st.IdeaID)
}

// TestPrefix_NotOnRegenerate: a regenerate reuses the owner row, so its
// prefix never runs twice; an edit writes a new owner row and does run it.
func TestPrefix_NotOnRegenerate(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	first := send(t, s, conv, "факт: the build runs nightly")
	require.NotZero(t, first.IdeaID)
	done := ev(chat.EventTurnDone, first.TurnID)
	done.Status = chat.StatusComplete
	require.NoError(t, s.Turn(first).Apply(done))
	ideas := func() int {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM ideas`).Scan(&n))
		return n
	}
	require.Equal(t, 1, ideas())

	regen, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeRegenerate, MessageID: first.AssistantMessageID})
	require.NoError(t, err)
	assert.Zero(t, regen.IdeaID)
	assert.Equal(t, 1, ideas())
	stop := s.Turn(regen)
	require.NoError(t, stop.Finalize(StatusPartial, nil))

	edit, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeEdit, MessageID: first.UserMessageID, Text: "факт: the build runs hourly"})
	require.NoError(t, err)
	assert.NotZero(t, edit.IdeaID)
	assert.Equal(t, 2, ideas())
}

// TestFinalize_TitleHookOnFirstAnswer: the hook fires after the first
// complete answer of a prefix-titled chat, once.
func TestFinalize_TitleHookOnFirstAnswer(t *testing.T) {
	var called []int64
	d, s, _ := newStore(t, WithTitleHook(func(conv int64) { called = append(called, conv) }))
	conv := newConversation(t, d)
	complete := func(st Started) {
		e := ev(chat.EventTurnDone, st.TurnID)
		e.Status = chat.StatusComplete
		require.NoError(t, s.Turn(st).Apply(e))
	}
	first := send(t, s, conv, "one")
	require.NoError(t, s.Turn(first).Finalize(StatusError, &Failure{Code: chat.CodeInternal}))
	assert.Empty(t, called, "no complete answer yet")
	regen, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeRegenerate, MessageID: first.AssistantMessageID})
	require.NoError(t, err)
	complete(regen)
	assert.Equal(t, []int64{conv}, called)
	complete(send(t, s, conv, "two"))
	assert.Equal(t, []int64{conv}, called, "only after the first")

	named := newConversation(t, d)
	_, err = d.Exec(`UPDATE chat_conversations SET title = 'Mine', title_source = 'user' WHERE id = ?`, named)
	require.NoError(t, err)
	complete(send(t, s, named, "x"))
	assert.Equal(t, []int64{conv}, called, "never for an owner title")
}

type outcomesCase struct {
	Name           string   `json:"name"`
	ConversationID int64    `json:"conversation_id"`
	After          *float64 `json:"after"`
	Rows           []struct {
		ID             int64
		Tool, Status   string
		ConversationID int64  `json:"conversation_id"`
		CreatedAt      string `json:"created_at"`
		DecidedAt      string `json:"decided_at"`
		AppliedAt      string `json:"applied_at"`
		ResultJSON     string `json:"result_json"`
		Error          string
	} `json:"rows"`
	Expect *string `json:"expect"`
}

// TestOutcomesBlock_SharedCases runs outcomes_block_cases.json, which the
// Swift OutcomesBlockFixtureTests reads too.
func TestOutcomesBlock_SharedCases(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "outcomes_block_cases.json"))
	require.NoError(t, err)
	var cases []outcomesCase
	require.NoError(t, json.Unmarshal(raw, &cases))
	require.GreaterOrEqual(t, len(cases), 6)
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			d := openDB(t)
			for _, r := range tc.Rows {
				_, err := d.Exec(`INSERT INTO agent_actions (id, tool, args_json, conversation_id, status, result_json, error, created_at, decided_at, applied_at)
					VALUES (?, ?, '{}', ?, ?, ?, ?, ?, ?, ?)`, r.ID, r.Tool, r.ConversationID, r.Status, r.ResultJSON, r.Error, r.CreatedAt, r.DecidedAt, r.AppliedAt)
				require.NoError(t, err)
			}
			got := ""
			if tc.After != nil {
				require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
					var err error
					got, err = outcomesBlockTx(tx, tc.ConversationID, *tc.After)
					return err
				}))
			}
			want := ""
			if tc.Expect != nil {
				want = *tc.Expect
			}
			assert.Equal(t, want, got)
		})
	}
}

// TestFinalize_RetriesAfterWriteFailure: a finalize whose write fails (a
// lock held past busy_timeout) leaves the turn running; the retried
// Finalize commits and releases the lease.
func TestFinalize_RetriesAfterWriteFailure(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	st := send(t, s, conv, "hi")
	turn := s.Turn(st)
	require.NoError(t, turn.Apply(deltaEv(st.TurnID, "Answer")))
	busy := errors.New("database is locked")
	s.failWrite = func() error { return busy }
	done := ev(chat.EventTurnDone, st.TurnID)
	done.Status = chat.StatusComplete
	assert.ErrorIs(t, turn.Apply(done), busy)
	finished, _ := turn.Done()
	assert.False(t, finished, "the end is not on disk: the turn still runs")
	lease, err := d.GetChatLease(conv)
	require.NoError(t, err)
	require.NotNil(t, lease, "the lease stays until the end commits")

	s.failWrite = nil
	require.NoError(t, turn.Finalize(StatusComplete, nil))
	m, _ := message(t, d, st.AssistantMessageID)
	assert.Equal(t, msgState{Role: "assistant", Text: "Answer", Status: "complete", TurnID: st.TurnID}, m)
	lease, err = d.GetChatLease(conv)
	require.NoError(t, err)
	assert.Nil(t, lease)
	finished, status := turn.Done()
	assert.True(t, finished)
	assert.Equal(t, StatusComplete, status)
}

// TestStart_LinkedAttachmentRefusedOnSend: a send names pending files only —
// a file already linked to a message would be sent but never linked — while a
// regenerate still re-sends its owner message's linked files.
func TestStart_LinkedAttachmentRefusedOnSend(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	res, err := d.Exec(`INSERT INTO chat_attachments (conversation_id, name, mime, size, path, sha256, created_at)
		VALUES (?, 'a.png', 'image/png', 1, '/files/a.png', 's', 1)`, conv)
	require.NoError(t, err)
	file, _ := res.LastInsertId()
	first, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeSend, Text: "look", AttachmentIDs: []int64{file}})
	require.NoError(t, err)
	require.Len(t, first.Attachments, 1)
	done := ev(chat.EventTurnDone, first.TurnID)
	done.Status = chat.StatusComplete
	require.NoError(t, s.Turn(first).Apply(done))

	var before int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages`).Scan(&before))
	_, err = s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeSend, Text: "again", AttachmentIDs: []int64{file}})
	assert.ErrorIs(t, err, ErrAttachmentMissing)
	var after int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages`).Scan(&after))
	assert.Equal(t, before, after)

	regen, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeRegenerate, MessageID: first.AssistantMessageID})
	require.NoError(t, err)
	assert.Equal(t, []chat.Attachment{{Path: "/files/a.png", Mime: "image/png", Name: "a.png"}}, regen.Attachments)
}

// TestPrefix_RememberInLiveChatOnlyOwnerText: in a conversation marked by
// the Live Slack connector (LIVE-01) a remember stores the owner's own words
// and refuses a line that is not in the owner's message.
func TestPrefix_RememberInLiveChatOnlyOwnerText(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	first := send(t, s, conv, "what is new in eng?")
	turn := s.Turn(first)
	require.NoError(t, turn.Apply(toolStart(first.TurnID, "s-1", "claude_ai_Slack:slack_read_channel")))
	require.NoError(t, turn.Finalize(StatusComplete, nil))

	st := send(t, s, conv, "remember: answer in short bullets")
	require.NoError(t, st.PrefixErr)
	assert.Equal(t, string(db.RememberAdded), st.RememberOutcome, "the owner's own words")

	outcome, _, err := s.remember("the launch moved to Friday", conv, st.UserMessageID)
	require.NoError(t, err)
	assert.Equal(t, RememberNotOwnerText, outcome)
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.NotContains(t, got.Chat, "launch moved")
	assert.Contains(t, got.Chat, "answer in short bullets")
}

func insertMsg(t *testing.T, d *db.DB, conv int64, parent any, role, text, turn string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id, status)
		VALUES (?, ?, ?, ?, 1, ?, 'complete')`, conv, parent, role, text, turn)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func insertComment(t *testing.T, d *db.DB, conv int64, status string) int64 {
	t.Helper()
	var sentAt any
	if status == "sent" {
		sentAt = 1.0
	}
	res, err := d.Exec(`INSERT INTO chat_artifact_comments (conversation_id, artifact_key, artifact_version, body, anchor_quote, status, created_at, sent_at)
		VALUES (?, 'doc', 1, 'why?', 'a passage', ?, 1, ?)`, conv, status, sentAt)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// TestStart_QuoteBatchRows: the "Send N comments" batch turns its open
// comments sent in the owner row's transaction (the Mac's alsoWrite →
// ArtifactCommentQueries.markSent); a comment already sent or resolved, or
// one of another conversation, is left alone; a refused start writes none.
func TestStart_QuoteBatchRows(t *testing.T) {
	d, s, clock := newStore(t)
	conv := newConversation(t, d)
	other := newConversation(t, d)
	open1, open2 := insertComment(t, d, conv, "open"), insertComment(t, d, conv, "open")
	resolved := insertComment(t, d, conv, "resolved")
	foreign := insertComment(t, d, other, "open")
	untouched := insertComment(t, d, conv, "open")

	composed := "About the doc:\n> a passage\nwhy?"
	title := "About the doc"
	st, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeSend, Text: composed, TitleText: &title,
		TurnID: "t1", Quotes: []Quote{{CommentID: open1}, {CommentID: open2}, {CommentID: resolved}, {CommentID: foreign}}})
	require.NoError(t, err)
	owner, ok := message(t, d, st.UserMessageID)
	require.True(t, ok)
	assert.Equal(t, composed, owner.Text, "the client-composed text is stored as given")
	var convTitle string
	require.NoError(t, d.QueryRow(`SELECT title FROM chat_conversations WHERE id = ?`, conv).Scan(&convTitle))
	assert.Equal(t, title, convTitle, "the prefix title comes from title_text")

	status := func(id int64) (string, sql.NullFloat64) {
		var st string
		var at sql.NullFloat64
		require.NoError(t, d.QueryRow(`SELECT status, sent_at FROM chat_artifact_comments WHERE id = ?`, id).Scan(&st, &at))
		return st, at
	}
	for _, id := range []int64{open1, open2} {
		got, at := status(id)
		assert.Equal(t, "sent", got)
		assert.InDelta(t, seconds(clock.now()), at.Float64, 0.001)
	}
	got, _ := status(resolved)
	assert.Equal(t, "resolved", got)
	got, _ = status(foreign)
	assert.Equal(t, "open", got, "a comment of another conversation is never marked")
	got, _ = status(untouched)
	assert.Equal(t, "open", got)

	// A refused start (the lease is held) writes no comment.
	_, err = s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeSend, Text: "again", TurnID: "t2",
		Quotes: []Quote{{CommentID: untouched}}})
	require.ErrorIs(t, err, ErrBusy)
	got, _ = status(untouched)
	assert.Equal(t, "open", got)

	// Quotes and title_text belong to a new message only.
	for _, r := range []StartRequest{
		{ConversationID: conv, Mode: ModeEdit, MessageID: st.UserMessageID, Text: "x", Quotes: []Quote{{CommentID: untouched}}},
		{ConversationID: conv, Mode: ModeEdit, MessageID: st.UserMessageID, Text: "x", TitleText: &title},
		{ConversationID: conv, Mode: ModeRegenerate, MessageID: st.AssistantMessageID, Quotes: []Quote{{CommentID: untouched}}},
	} {
		_, err := s.Start(context.Background(), r)
		assert.ErrorIs(t, err, ErrInvalid)
	}
}

// TestStart_RegenerateReusesTheOwnerMessage: a regenerate named by its owner
// message (the Mac's reuseUserMessageID) writes no owner row, no placeholder
// and no title: only the new partial reply under the reused message, which
// resends its files and replays.
func TestStart_RegenerateReusesTheOwnerMessage(t *testing.T) {
	d, s, _ := newStore(t)
	conv := newConversation(t, d)
	u1 := insertMsg(t, d, conv, nil, "user", "first question", "t0")
	a1 := insertMsg(t, d, conv, u1, "assistant", "first answer", "t0")
	_, err := d.Exec(`INSERT INTO chat_attachments (conversation_id, message_id, name, mime, size, path, sha256, created_at)
		VALUES (?, ?, 'a.png', 'image/png', 1, '/tmp/a.png', 'sha', 1)`, conv, u1)
	require.NoError(t, err)

	st, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeRegenerate, ReuseOwnerMessageID: u1, TurnID: "t1"})
	require.NoError(t, err)
	assert.Equal(t, u1, st.UserMessageID)
	assert.True(t, st.Replay)
	assert.Equal(t, "first question", st.SendText)
	require.Len(t, st.Attachments, 1)
	assert.Equal(t, "a.png", st.Attachments[0].Name)

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`, conv).Scan(&n))
	assert.Equal(t, 3, n, "only the new reply")
	var parent int64
	require.NoError(t, d.QueryRow(`SELECT parent_id FROM chat_messages WHERE id = ?`, st.AssistantMessageID).Scan(&parent))
	assert.Equal(t, u1, parent)
	assert.NotEqual(t, a1, st.AssistantMessageID)

	require.NoError(t, s.Turn(st).Finalize(StatusComplete, nil)) // releases the lease
	// Not an owner message, unknown, or both targets at once: refused.
	_, err = s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeRegenerate, ReuseOwnerMessageID: a1})
	assert.ErrorIs(t, err, ErrInvalid)
	_, err = s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeRegenerate, ReuseOwnerMessageID: 9999})
	assert.ErrorIs(t, err, ErrNotFound)
	_, err = s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeRegenerate, ReuseOwnerMessageID: u1, MessageID: a1})
	assert.ErrorIs(t, err, ErrInvalid)
}

// TestStart_EditReusesAndWritesThePlaceholder: an edit keeps the original's
// files and parent; when that parent is a legacy owner question nobody
// answered, its empty partial reply is written first and the edited
// sibling sits under it (persistTurnStart's answerIfOwnerMessage).
func TestStart_EditReusesAndWritesThePlaceholder(t *testing.T) {
	d, s, _ := newStore(t, WithPreferredProvider("claude"))
	conv := newConversation(t, d)
	legacy := insertMsg(t, d, conv, nil, "user", "a legacy question", "old")
	u1 := insertMsg(t, d, conv, legacy, "user", "the original", "t0")
	_, err := d.Exec(`INSERT INTO chat_attachments (conversation_id, message_id, name, mime, size, path, sha256, created_at)
		VALUES (?, ?, 'a.pdf', 'application/pdf', 1, '/tmp/a.pdf', 'sha', 1)`, conv, u1)
	require.NoError(t, err)

	st, err := s.Start(context.Background(), StartRequest{ConversationID: conv, Mode: ModeEdit, MessageID: u1, Text: "the edit", TurnID: "t1"})
	require.NoError(t, err)
	require.Len(t, st.Attachments, 1, "the original's files are sent again")

	var placeholder int64
	var role, text, status, turn, provider string
	require.NoError(t, d.QueryRow(`SELECT id, role, text, status, turn_id, provider FROM chat_messages WHERE parent_id = ? AND role = 'assistant'`, legacy).
		Scan(&placeholder, &role, &text, &status, &turn, &provider))
	assert.Equal(t, []string{"assistant", "", "partial", "old", "claude"}, []string{role, text, status, turn, provider})
	var parent int64
	require.NoError(t, d.QueryRow(`SELECT parent_id FROM chat_messages WHERE id = ?`, st.UserMessageID).Scan(&parent))
	assert.Equal(t, placeholder, parent, "the edited sibling sits under the placeholder")
	assert.NotEqual(t, u1, st.UserMessageID)
	var link int64
	require.NoError(t, d.QueryRow(`SELECT message_id FROM chat_attachments WHERE conversation_id = ?`, conv).Scan(&link))
	assert.Equal(t, u1, link, "the files stay on the original")
}
