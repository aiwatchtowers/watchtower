package delivery

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionmsg"
)

// Every row is re-checked before typing, whoever queued it: a row addressed
// to a shell row or to another bench's session fails without telling
// anyone, and nothing is typed.
func TestNeverDeliveredToANonPeer(t *testing.T) {
	w := newWorld(t)
	from := w.session(t, "A", "waiting", 0)
	res, err := w.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'zsh', '/tmp/acme')`, w.wb)
	require.NoError(t, err)
	shell, err := res.LastInsertId()
	require.NoError(t, err)
	other, err := w.d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	res, err = w.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'codex', 'x', '/tmp/x')`, other)
	require.NoError(t, err)
	elsewhere, err := res.LastInsertId()
	require.NoError(t, err)
	w.port.setRun(shell, runStart, true)
	w.port.setRun(elsewhere, runStart, true)
	toShell := w.queue(t, sessionmsg.KindFailure, from, shell, "[Message to #1 not delivered: x]")
	toOther := w.queue(t, sessionmsg.KindMessage, from, elsewhere, "hi")

	w.del.Tick(t.Context())

	assert.Equal(t, row{state: "failed", reason: "not_a_peer"}, w.row(t, toShell))
	assert.Equal(t, row{state: "failed", reason: "not_a_peer"}, w.row(t, toOther))
	assert.Empty(t, w.port.deliveries())
	assert.Empty(t, w.toSession(t, from), "nobody is told")
}

// A permission prompt that opened after the gate read: the host writes
// nothing (held_dialog) and the row goes back to the queue.
func TestHeldAtADialogIsRequeued(t *testing.T) {
	w := newWorld(t)
	from, to := w.session(t, "A", "waiting", 0), w.session(t, "B", "waiting", 0)
	w.port.setRun(to, runStart, true)
	w.port.outcomes = []handlers.DeliverResult{{Outcome: handlers.DeliverHeld, Reason: sessionhost.HeldDialog}}
	id := w.queue(t, sessionmsg.KindMessage, from, to, "hi")
	w.del.Tick(t.Context())
	assert.Equal(t, "queued", w.row(t, id).state)
	w.del.Tick(t.Context())
	assert.Equal(t, "delivered", w.row(t, id).state)
}

// A run lost after the paste is final: never requeued (it may have landed),
// the sender told it may not have arrived; a finished line too.
func TestRunLostAfterThePasteIsFinal(t *testing.T) {
	w := newWorld(t)
	parent := w.session(t, "Lead", "waiting", 0)
	from, to := w.session(t, "A", "waiting", 0), w.session(t, "B", "waiting", parent)
	w.port.setRun(to, runStart, true)
	w.port.setRun(parent, runStart, true)
	lost := handlers.DeliverResult{Outcome: handlers.DeliverNoSession, Reason: sessionhost.LostAfterPaste}
	w.port.outcomes = []handlers.DeliverResult{lost, lost}
	id := w.queue(t, sessionmsg.KindMessage, from, to, "hi")
	fin := w.queue(t, sessionmsg.KindFinished, to, parent, "done")

	w.del.Tick(t.Context())
	assert.Equal(t, row{state: "failed", reason: "delivery_unknown"}, w.row(t, id))
	assert.Equal(t, row{state: "failed", reason: "delivery_unknown"}, w.row(t, fin))
	requireTold(t, w, from, sessionmsg.DeliveryUnknownLine(to))

	w.del.Tick(t.Context())
	assert.Len(t, w.port.deliveries(), 2, "each pasted once, never again")
}

// delivered_at keeps milliseconds: a prompt's `working` stamped in the same
// second but before the paste never clears the flag; one after it does.
func TestPromptFlagSubSecondPrecision(t *testing.T) {
	w := newWorld(t)
	from, to := w.session(t, "A", "waiting", 0), w.session(t, "B", "waiting", 0)
	w.port.setRun(to, runStart, true)
	pasted := sentAt.Add(500 * time.Millisecond)
	id := w.queue(t, sessionmsg.KindMessage, from, to, "hi")
	_, err := w.d.ClaimSessionMessage(t.Context(), id)
	require.NoError(t, err)
	require.NoError(t, w.d.SettleSessionMessage(t.Context(), id, db.SessionMessageDelivered,
		db.SessionMessageTypedNotSubmitted, pasted))

	w.setState(t, to, "working", sentAt.Add(200*time.Millisecond), false)
	w.del.Tick(t.Context())
	assert.False(t, w.row(t, id).cleared, "a prompt from before the paste, same second")

	w.setState(t, to, "working", sentAt.Add(800*time.Millisecond), false)
	w.del.Tick(t.Context())
	assert.True(t, w.row(t, id).cleared)
}

// A row another tick claimed meanwhile is never failed by this tick's stale
// read of the queue, and nobody is told.
func TestPreClaimFailuresNeverTouchAClaimedRow(t *testing.T) {
	w := newWorld(t)
	from, to := w.session(t, "A", "waiting", 0), w.session(t, "B", "waiting", 0)
	id := w.queue(t, sessionmsg.KindMessage, from, to, "hi")
	queued, err := w.d.QueuedSessionMessages(t.Context())
	require.NoError(t, err)
	require.Len(t, queued, 1)
	claimed, err := w.d.ClaimSessionMessage(t.Context(), id)
	require.NoError(t, err)
	require.True(t, claimed)

	w.del.init()
	w.del.deliver(t.Context(), queued[0], map[int64]time.Time{}) // target not running
	assert.Equal(t, "delivering", w.row(t, id).state)
	assert.Empty(t, w.toSession(t, from))
}
