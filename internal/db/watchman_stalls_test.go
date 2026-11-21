package db

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestWatchmanStall_RoundTrip(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)

	st, err := d.WatchmanStall(s)
	require.NoError(t, err)
	require.Nil(t, st, "no row yet")

	stopped := time.Date(2026, 11, 21, 10, 0, 0, 123456789, time.UTC)
	ping := stopped.Add(3 * time.Minute)
	require.NoError(t, d.UpsertWatchmanStall(WatchmanStallRow{SessionID: s, StoppedAt: stopped, Pings: 1, LastPingAt: &ping,
		Head: "abc123", AsksSeen: 2}))
	st, err = d.WatchmanStall(s)
	require.NoError(t, err)
	require.NotNil(t, st)
	assert.True(t, st.StoppedAt.Equal(stopped), "nanoseconds kept")
	assert.Equal(t, 1, st.Pings)
	require.NotNil(t, st.LastPingAt)
	assert.True(t, st.LastPingAt.Equal(ping))
	assert.Equal(t, "abc123", st.Head)
	assert.Equal(t, 2, st.AsksSeen)
	assert.Nil(t, st.ParkedAt)

	parked := ping.Add(5 * time.Minute)
	st.Pings, st.ParkedAt = 3, &parked
	require.NoError(t, d.UpsertWatchmanStall(*st))
	st, err = d.WatchmanStall(s)
	require.NoError(t, err)
	assert.Equal(t, 3, st.Pings)
	require.NotNil(t, st.ParkedAt)
	assert.True(t, st.ParkedAt.Equal(parked))

	require.NoError(t, d.DeleteWatchmanStall(s))
	st, err = d.WatchmanStall(s)
	require.NoError(t, err)
	assert.Nil(t, st)
	require.NoError(t, d.DeleteWatchmanStall(s), "deleting no row is fine")
}

// The stall counts go with the arming: a session taken back, finished or
// being deleted loses its row; one armed directly or under an armed target
// keeps it. A deleted session's row cascades.
func TestWatchmanStalls_PrunedWithArming(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	target := insertWorkbenchTargetRow(t, d, wb, "board item")
	armed := newTestSession(t, d, wb)
	underTarget := newTestSession(t, d, wb)
	taken := newTestSession(t, d, wb)
	finished := newTestSession(t, d, wb)
	deleting := newTestSession(t, d, wb)
	gone := newTestSession(t, d, wb)
	_, err := d.Exec(`UPDATE terminal_sessions SET target_id = ? WHERE id = ?`, target, underTarget)
	require.NoError(t, err)
	wmArmSession(t, d, armed)
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "target", RefID: target, ArmedAt: time.Now(), ArmedBy: "cli"}))
	for _, s := range []int64{taken, finished, deleting, gone} {
		wmArmSession(t, d, s)
	}
	for _, s := range []int64{armed, underTarget, taken, finished, deleting, gone} {
		require.NoError(t, d.UpsertWatchmanStall(WatchmanStallRow{SessionID: s, StoppedAt: time.Now(), Pings: 1}))
	}
	_, err = d.DeleteWatchmanArming("session", taken)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE terminal_sessions SET finished_at = ? WHERE id = ?`, AgentStateStamp(time.Now()), finished)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE terminal_sessions SET delete_requested_at = ? WHERE id = ?`, AgentStateStamp(time.Now()), deleting)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, gone)
	require.NoError(t, err)

	n, err := d.PruneWatchmanStalls()
	require.NoError(t, err)
	assert.EqualValues(t, 3, n, "taken back, finished, being deleted (the deleted one cascaded)")
	var left []int64
	rows, err := d.Query(`SELECT session_id FROM watchman_stalls ORDER BY session_id`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var id int64
		require.NoError(t, rows.Scan(&id))
		left = append(left, id)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, []int64{armed, underTarget}, left)
}

func stallItems(t *testing.T, d *DB, session int64) []WatchmanItem {
	t.Helper()
	rows, err := d.Query(`SELECT `+watchmanItemCols+` FROM watchman_items WHERE kind = 'stall' AND ref_id = ? ORDER BY id`, session)
	require.NoError(t, err)
	defer rows.Close()
	var out []WatchmanItem
	for rows.Next() {
		it, err := scanWatchmanItem(rows)
		require.NoError(t, err)
		out = append(out, *it)
	}
	require.NoError(t, rows.Err())
	return out
}

// A stall item is a finished park of ref ('session', S), unsure; one waits
// per session at a time, and one the owner marked done gives way to the next.
func TestInsertWatchmanStallItem_OnePerOpenStall(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	target := insertWorkbenchTargetRow(t, d, wb, "board item")
	s := newTestSession(t, d, wb)
	at := time.Date(2026, 11, 21, 10, 0, 0, 0, time.UTC)
	const reason = "The agent stopped and did not go on after 3 pings"

	require.NoError(t, d.InsertWatchmanStallItem(s, target, wb, reason, at))
	first := stallItems(t, d, s)
	require.Len(t, first, 1)
	const stuck = "The agent stopped and Watchman could not get a ping through for 9 minutes"
	require.NoError(t, d.InsertWatchmanStallItem(s, target, wb, stuck, at.Add(time.Hour)), "an open one: no second item")
	items := stallItems(t, d, s)
	require.Len(t, items, 1)
	assert.Equal(t, first[0].ID, items[0].ID, "the open item keeps its id")
	assert.Equal(t, stuck, items[0].ParkReason, "a re-park updates the reason")
	require.NoError(t, d.InsertWatchmanStallItem(s, target, wb, reason, at.Add(time.Hour)))
	items = stallItems(t, d, s)
	require.Len(t, items, 1)
	it := items[0]
	assert.Equal(t, "session", it.RefKind)
	assert.Equal(t, s, it.SessionID)
	assert.Equal(t, target, it.TargetID)
	assert.Equal(t, wb, it.WorkbenchID)
	assert.Equal(t, "done", it.State)
	assert.Equal(t, "parked", it.Outcome)
	assert.Equal(t, reason, it.ParkReason)
	assert.True(t, it.Unsure)
	assert.True(t, it.CreatedAt.Equal(at))
	require.NotNil(t, it.DecidedAt)
	assert.True(t, it.DecidedAt.Equal(at))
	done, err := d.WatchmanStallItemDone(s)
	require.NoError(t, err)
	assert.False(t, done)

	_, err = d.Exec(`UPDATE watchman_items SET owner_done_at = ? WHERE id = ?`, wmTime(at.Add(2*time.Hour)), it.ID)
	require.NoError(t, err)
	done, err = d.WatchmanStallItemDone(s)
	require.NoError(t, err)
	assert.True(t, done, "Mark done")

	later := at.Add(3 * time.Hour)
	require.NoError(t, d.InsertWatchmanStallItem(s, 0, wb, reason, later))
	items = stallItems(t, d, s)
	require.Len(t, items, 1, "the marked-done item gave way")
	assert.NotEqual(t, it.ID, items[0].ID)
	assert.True(t, items[0].CreatedAt.Equal(later))
	assert.Zero(t, items[0].TargetID)
	done, err = d.WatchmanStallItemDone(s)
	require.NoError(t, err)
	assert.False(t, done)
}

// ParkWatchmanStall writes the item and the parked row in one transaction
// that re-checks the arming: a session taken back gets neither.
func TestParkWatchmanStall_RechecksArming(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	at := time.Date(2026, 11, 21, 10, 0, 0, 0, time.UTC)
	row := WatchmanStallRow{SessionID: s, StoppedAt: at.Add(-10 * time.Minute), Pings: 1, LastDelivery: "typed"}

	parked, err := d.ParkWatchmanStall(row, 0, wb, "reason", at)
	require.NoError(t, err)
	assert.False(t, parked, "not armed")
	assert.Empty(t, stallItems(t, d, s))
	st, err := d.WatchmanStall(s)
	require.NoError(t, err)
	assert.Nil(t, st)

	wmArmSession(t, d, s)
	parked, err = d.ParkWatchmanStall(row, 0, wb, "reason", at)
	require.NoError(t, err)
	assert.True(t, parked)
	items := stallItems(t, d, s)
	require.Len(t, items, 1)
	assert.Equal(t, "reason", items[0].ParkReason)
	st, err = d.WatchmanStall(s)
	require.NoError(t, err)
	require.NotNil(t, st.ParkedAt)
	assert.True(t, st.ParkedAt.Equal(at))
	assert.Equal(t, "typed", st.LastDelivery)
}

// A stall item waits for the owner (the Inbox count) until Mark done, and
// is never counted as a decision.
func TestWatchmanJournalSummary_StallWaitsUntilMarkDone(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	at := time.Now().UTC().Truncate(time.Second)
	require.NoError(t, d.InsertWatchmanStallItem(s, 0, wb, "The agent stopped and did not go on after 3 pings", at))

	summary := func() *WatchmanJournalSummary {
		t.Helper()
		var out *WatchmanJournalSummary
		require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
			var err error
			out, err = WatchmanJournalSummaryTx(context.Background(), tx, time.UTC)
			return err
		}))
		require.NotNil(t, out)
		return out
	}
	got := summary()
	assert.Equal(t, 1, got.Waiting)
	assert.Zero(t, got.Decided)

	_, err := d.Exec(`UPDATE watchman_items SET owner_done_at = ? WHERE kind = 'stall'`, wmTime(at))
	require.NoError(t, err)
	got = summary()
	assert.Zero(t, got.Waiting, "Mark done")
	assert.Zero(t, got.Decided)
}

// 00212 rebuilds watchman_items with 'stall' in its kind CHECK: every row,
// column, index, the foreign key and the AUTOINCREMENT mark survive; an
// unknown kind is still refused. The Down drops the stall items and table.
func TestMigration00212_StallKindRebuildKeepsRows(t *testing.T) {
	t.Parallel()
	raw, err := sql.Open("sqlite3", ":memory:")
	require.NoError(t, err)
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	_, err = raw.Exec(`PRAGMA foreign_keys = ON`)
	require.NoError(t, err)
	require.NoError(t, gooseUpTo(raw, "migrations", 211))
	_, err = raw.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO terminal_sessions (id, project_id, kind, title, folder_path, claude_session_id)
		VALUES (10, 1, 'claude', 'New session', '/tmp/acme', 'uuid')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO watchman_items (id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome,
			attempts, question, choice, unsure, park_reason, cost_usd, created_at, decided_at, feedback, feedback_text, feedback_at,
			owner_done_at, correction_sent_at, moves)
		VALUES (40, 1, 10, NULL, 'review_code', 'session', 10, 'done', 'changes', 2, 'q', 'changes', 1, '', 0.5,
			'2026-11-20T09:00:00Z', '2026-11-20T09:05:00Z', 'corrected', 'fix it', '2026-11-20T10:00:00Z',
			'2026-11-20T11:00:00Z', '2026-11-20T10:01:00Z', 2)`)
	require.NoError(t, err)
	_, err = raw.Exec(`DELETE FROM watchman_items WHERE id = 40`) // the high-water mark stays 40
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO watchman_items (id, workbench_id, session_id, kind, ref_kind, ref_id, state, outcome,
			attempts, question, choice, unsure, park_reason, cost_usd, created_at, decided_at, feedback, feedback_text, feedback_at,
			owner_done_at, correction_sent_at, moves)
		VALUES (7, 1, 10, 'review_code', 'session', 10, 'done', 'changes', 2, 'q', 'changes', 1, '', 0.5,
			'2026-11-20T09:00:00Z', '2026-11-20T09:05:00Z', 'corrected', 'fix it', '2026-11-20T10:00:00Z',
			'2026-11-20T11:00:00Z', '2026-11-20T10:01:00Z', 2)`)
	require.NoError(t, err)

	require.NoError(t, gooseUpTo(raw, "migrations", 212))

	var kind, outcome, feedbackText, ownerDone, sent string
	var attempts, moves int
	var cost float64
	require.NoError(t, raw.QueryRow(`SELECT kind, outcome, attempts, cost_usd, feedback_text, owner_done_at, correction_sent_at, moves
		FROM watchman_items WHERE id = 7`).Scan(&kind, &outcome, &attempts, &cost, &feedbackText, &ownerDone, &sent, &moves))
	assert.Equal(t, "review_code", kind)
	assert.Equal(t, "changes", outcome)
	assert.Equal(t, 2, attempts)
	assert.InDelta(t, 0.5, cost, 1e-9)
	assert.Equal(t, "fix it", feedbackText)
	assert.Equal(t, "2026-11-20T11:00:00Z", ownerDone)
	assert.Equal(t, "2026-11-20T10:01:00Z", sent)
	assert.Equal(t, 2, moves)
	for _, idx := range []string{"idx_watchman_items_queue", "idx_watchman_items_wb", "idx_watchman_items_created"} {
		var n int
		require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?`, idx).Scan(&n))
		assert.Equal(t, 1, n, idx)
	}
	var fkTable string
	require.NoError(t, raw.QueryRow(`SELECT "table" FROM pragma_foreign_key_list('watchman_items')`).Scan(&fkTable))
	assert.Equal(t, "projects", fkTable)
	var seq int64
	require.NoError(t, raw.QueryRow(`SELECT seq FROM sqlite_sequence WHERE name = 'watchman_items'`).Scan(&seq))
	assert.EqualValues(t, 40, seq, "the AUTOINCREMENT mark is carried")
	var fkOn int
	require.NoError(t, raw.QueryRow(`PRAGMA foreign_keys`).Scan(&fkOn))
	assert.Equal(t, 1, fkOn, "foreign keys are back on")

	_, err = raw.Exec(`INSERT INTO watchman_items (workbench_id, session_id, kind, ref_kind, ref_id, state, outcome, park_reason, created_at)
		VALUES (1, 10, 'stall', 'session', 10, 'done', 'parked', 'stopped', '2026-11-21T09:00:00Z')`)
	require.NoError(t, err, "'stall' is accepted")
	_, err = raw.Exec(`INSERT INTO watchman_items (workbench_id, kind, ref_kind, ref_id, created_at)
		VALUES (1, 'bogus', 'session', 11, '2026-11-21T09:00:00Z')`)
	require.Error(t, err, "an unknown kind is refused")
	_, err = raw.Exec(`INSERT INTO watchman_stalls (session_id, stopped_at) VALUES (10, '2026-11-21T09:00:00Z')`)
	require.NoError(t, err)
	_, err = raw.Exec(`DELETE FROM terminal_sessions WHERE id = 10`)
	require.NoError(t, err)
	var stalls int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM watchman_stalls`).Scan(&stalls))
	assert.Zero(t, stalls, "a deleted session's count cascades")

	require.NoError(t, gooseDownTo(raw, "migrations", 211))
	var n int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM watchman_items WHERE kind = 'stall'`).Scan(&n))
	assert.Zero(t, n, "the Down drops the stall items")
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM watchman_items WHERE id = 7`).Scan(&n))
	assert.Equal(t, 1, n, "other rows stay")
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'watchman_stalls'`).Scan(&n))
	assert.Zero(t, n)
}

// A session's own item queued or being decided — any kind — is pending;
// a done one, or another session's, is not.
func TestWatchmanSessionItemsPending(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	other := newTestSession(t, d, wb)
	pending := func() bool {
		t.Helper()
		yes, err := d.WatchmanSessionItemsPending(s)
		require.NoError(t, err)
		return yes
	}
	insert := func(session int64, kind, refKind string, ref int64, state string) int64 {
		t.Helper()
		res, err := d.Exec(`INSERT INTO watchman_items (workbench_id, session_id, kind, ref_kind, ref_id, state, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`, wb, session, kind, refKind, ref, state, wmTime(time.Now()))
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		return id
	}
	assert.False(t, pending(), "no items")
	insert(s, "stall", "session", s, "done")
	insert(other, "review_code", "round", 7, "queued")
	assert.False(t, pending(), "a done item, another session's queued one")
	review := insert(s, "review_code", "round", 8, "queued")
	assert.True(t, pending(), "its code review queued")
	_, err := d.Exec(`UPDATE watchman_items SET state = 'deciding' WHERE id = ?`, review)
	require.NoError(t, err)
	assert.True(t, pending(), "its code review deciding")
	_, err = d.Exec(`UPDATE watchman_items SET state = 'done' WHERE id = ?`, review)
	require.NoError(t, err)
	assert.False(t, pending(), "decided")
	insert(s, "ask", "ask", 9, "queued")
	assert.True(t, pending(), "a question queued")
}

// Fix 8: a session ArmWatchmanSet newly arms — directly or under a target
// it arms — starts its stall count afresh (Take back and re-arm before the
// daemon's prune); one already armed keeps its row, and a re-arm that
// inserts nothing changes no stall row.
func TestArmWatchmanSet_ClearsStallsOfNewlyArmed(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	target := insertWorkbenchTargetRow(t, d, wb, "board item")
	kept := newTestSession(t, d, wb)
	retaken := newTestSession(t, d, wb)
	underTarget := newTestSession(t, d, wb)
	_, err := d.Exec(`UPDATE terminal_sessions SET target_id = ? WHERE id = ?`, target, underTarget)
	require.NoError(t, err)
	wmArmSession(t, d, kept)
	for _, s := range []int64{kept, retaken, underTarget} {
		require.NoError(t, d.UpsertWatchmanStall(WatchmanStallRow{SessionID: s, StoppedAt: time.Now(), Pings: 3}))
	}
	has := func(s int64) bool {
		t.Helper()
		st, err := d.WatchmanStall(s)
		require.NoError(t, err)
		return st != nil
	}
	now := time.Now()
	inserted, err := d.ArmWatchmanSet([]WatchmanArming{{Scope: "session", RefID: kept, ArmedAt: now, ArmedBy: "cli"}}, nil)
	require.NoError(t, err)
	assert.False(t, inserted)
	assert.True(t, has(kept), "a re-arm of an armed session keeps its count")

	inserted, err = d.ArmWatchmanSet([]WatchmanArming{
		{Scope: "session", RefID: kept, ArmedAt: now, ArmedBy: "cli"},
		{Scope: "session", RefID: retaken, ArmedAt: now, ArmedBy: "cli"},
		{Scope: "target", RefID: target, ArmedAt: now, ArmedBy: "cli"},
	}, nil)
	require.NoError(t, err)
	assert.True(t, inserted)
	assert.True(t, has(kept), "already armed: kept")
	assert.False(t, has(retaken), "newly armed: afresh")
	assert.False(t, has(underTarget), "newly armed under the target: afresh")
}
