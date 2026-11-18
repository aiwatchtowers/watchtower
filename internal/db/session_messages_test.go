package db

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newTestMessage(t *testing.T, d *DB, wb, from, to int64) int64 {
	t.Helper()
	id, err := d.InsertSessionMessage(context.Background(), SessionMessage{WorkbenchID: wb,
		FromSessionID: nullID(from), ToSessionID: nullID(to), Kind: "message", Text: "hello"})
	require.NoError(t, err)
	return id
}

func messageState(t *testing.T, d *DB, id int64) (state, reason string) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT state, reason FROM session_messages WHERE id = ?`, id).Scan(&state, &reason))
	return state, reason
}

func TestInsertSessionMessage_Queued(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a, b := newTestSession(t, d, wb), newTestSession(t, d, wb)
	id := newTestMessage(t, d, wb, a, b)

	queued, err := d.QueuedSessionMessages(ctx)
	require.NoError(t, err)
	require.Len(t, queued, 1)
	m := queued[0]
	assert.Equal(t, id, m.ID)
	assert.Equal(t, wb, m.WorkbenchID)
	assert.Equal(t, nullID(a), m.FromSessionID)
	assert.Equal(t, nullID(b), m.ToSessionID)
	assert.Equal(t, "message", m.Kind)
	assert.Equal(t, "hello", m.Text)
	assert.Equal(t, "queued", m.State)
	assert.NotEmpty(t, m.CreatedAt)
	assert.False(t, m.DeliveredAt.Valid)

	_, err = d.InsertSessionMessage(ctx, SessionMessage{WorkbenchID: wb, Kind: "shout", Text: "x"})
	assert.Error(t, err, "an unknown kind is refused")

	none, err := openTestDB(t).QueuedSessionMessages(ctx)
	require.NoError(t, err)
	assert.NotNil(t, none)
}

func TestClaimSessionMessage_OnlyOnce(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	id := newTestMessage(t, d, wb, newTestSession(t, d, wb), newTestSession(t, d, wb))

	first, err := d.ClaimSessionMessage(ctx, id)
	require.NoError(t, err)
	second, err := d.ClaimSessionMessage(ctx, id)
	require.NoError(t, err)
	assert.True(t, first)
	assert.False(t, second)
	state, _ := messageState(t, d, id)
	assert.Equal(t, "delivering", state)
}

func TestSettleAndRequeueSessionMessage(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a, b := newTestSession(t, d, wb), newTestSession(t, d, wb)
	at := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)

	held := newTestMessage(t, d, wb, a, b)
	_, err := d.ClaimSessionMessage(ctx, held)
	require.NoError(t, err)
	require.NoError(t, d.RequeueSessionMessage(ctx, held))
	state, _ := messageState(t, d, held)
	assert.Equal(t, "queued", state, "a held delivery goes back to the queue")
	assert.ErrorIs(t, d.RequeueSessionMessage(ctx, held), ErrSessionMessageNotPending, "only a delivering row requeues")

	typed := newTestMessage(t, d, wb, a, b)
	_, err = d.ClaimSessionMessage(ctx, typed)
	require.NoError(t, err)
	require.NoError(t, d.SettleSessionMessage(ctx, typed, "delivered", "typed_not_submitted", at))
	var deliveredAt string
	require.NoError(t, d.QueryRow(`SELECT delivered_at FROM session_messages WHERE id = ?`, typed).Scan(&deliveredAt))
	assert.Equal(t, "2026-11-18T12:00:00Z", deliveredAt)
	assert.ErrorIs(t, d.SettleSessionMessage(ctx, typed, "failed", "x", at), ErrSessionMessageNotPending,
		"a settled row stays settled")

	// A held line fails from the queue after 24 h.
	require.NoError(t, d.SettleSessionMessage(ctx, held, "failed", "not_running", at))
	state, reason := messageState(t, d, held)
	assert.Equal(t, "failed", state)
	assert.Equal(t, "not_running", reason)
	assert.Error(t, d.SettleSessionMessage(ctx, newTestMessage(t, d, wb, a, b), "queued", "", at),
		"settle only to delivered or failed")
}

func TestFailInFlightSessionMessages(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a, b := newTestSession(t, d, wb), newTestSession(t, d, wb)
	inFlight := newTestMessage(t, d, wb, a, b)
	queued := newTestMessage(t, d, wb, a, b)
	_, err := d.ClaimSessionMessage(ctx, inFlight)
	require.NoError(t, err)

	n, err := d.FailInFlightSessionMessages(ctx, "unknown_after_restart")
	require.NoError(t, err)
	assert.EqualValues(t, 1, n)
	state, reason := messageState(t, d, inFlight)
	assert.Equal(t, "failed", state)
	assert.Equal(t, "unknown_after_restart", reason)
	state, _ = messageState(t, d, queued)
	assert.Equal(t, "queued", state)
}

func TestUnclearedPromptMessages_AndClearPromptFlag(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a, b := newTestSession(t, d, wb), newTestSession(t, d, wb)
	at := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	typed := newTestMessage(t, d, wb, a, b)
	submitted := newTestMessage(t, d, wb, a, b)
	for id, reason := range map[int64]string{typed: "typed_not_submitted", submitted: ""} {
		_, err := d.ClaimSessionMessage(ctx, id)
		require.NoError(t, err)
		require.NoError(t, d.SettleSessionMessage(ctx, id, "delivered", reason, at))
	}

	waiting, err := d.UnclearedPromptMessages(ctx)
	require.NoError(t, err)
	require.Len(t, waiting, 1)
	assert.Equal(t, typed, waiting[0].ID)

	require.NoError(t, d.ClearPromptFlag(ctx, typed, at))
	require.NoError(t, d.ClearPromptFlag(ctx, typed, at.Add(time.Hour)))
	var cleared string
	require.NoError(t, d.QueryRow(`SELECT prompt_cleared_at FROM session_messages WHERE id = ?`, typed).Scan(&cleared))
	assert.Equal(t, "2026-11-18T12:00:00Z", cleared, "the first clear is kept")
	waiting, err = d.UnclearedPromptMessages(ctx)
	require.NoError(t, err)
	assert.Empty(t, waiting)
}

func TestSessionMessages_FollowTheirSessionsAndBench(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a, b := newTestSession(t, d, wb), newTestSession(t, d, wb)
	id := newTestMessage(t, d, wb, a, b)
	_, err := d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, a)
	require.NoError(t, err)
	var from any
	require.NoError(t, d.QueryRow(`SELECT from_session_id FROM session_messages WHERE id = ?`, id).Scan(&from))
	assert.Nil(t, from, "a gone sender clears the link, the row stays")
	require.NoError(t, d.DeleteWorkbench(wb))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM session_messages`).Scan(&n))
	assert.Zero(t, n)
}
