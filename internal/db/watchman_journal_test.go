package db

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func wmJournalSummary(t *testing.T, d *DB, loc *time.Location) *WatchmanJournalSummary {
	t.Helper()
	tx, err := d.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	require.NoError(t, err)
	defer func() { _ = tx.Rollback() }()
	s, err := WatchmanJournalSummaryTx(context.Background(), tx, loc)
	require.NoError(t, err)
	return s
}

// The waiting count takes a handover whose next session failed to start
// for good, not one whose start is still owed (WatchmanStartPending /
// WatchmanStartClaimed), and drops an item the owner marked done; that
// failed handover is not a decision of its night.
func TestWatchmanJournalSummary_WaitingAndFailedHandovers(t *testing.T) {
	d := openTestDB(t)
	require.Nil(t, wmJournalSummary(t, d, time.UTC), "no summary before Watchman was turned on")
	wmTestWorkbench(t, d, 1)
	for _, row := range []struct {
		id                       int
		kind, outcome, err, done string
	}{
		{1, "handover", "answered", "starting the next session: host busy", ""},
		{2, "handover", "answered", WatchmanStartPending, ""},
		{3, "handover", "answered", WatchmanStartClaimed, ""},
		{4, "ask", "parked", "", ""},
		{5, "ask", "parked", "", "2026-11-16T09:00:00Z"},
	} {
		var done any
		if row.done != "" {
			done = row.done
		}
		_, err := d.Exec(`INSERT INTO watchman_items (id, workbench_id, kind, ref_kind, ref_id, state, outcome, error,
			owner_done_at, created_at) VALUES (?, 1, ?, 'session', ?, 'done', ?, ?, ?, ?)`,
			row.id, row.kind, row.id, row.outcome, row.err, done, "2026-11-16T0"+string(rune('0'+row.id))+":00:00Z")
		require.NoError(t, err)
	}
	s := wmJournalSummary(t, d, time.UTC)
	require.NotNil(t, s)
	require.Equal(t, 2, s.Waiting, "the failed handover and the parked ask")
	require.Equal(t, 2, s.Decided, "the two owed handovers; waiting and marked-done items are not decisions")
	require.Equal(t, time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC), s.NightStart)
	require.Equal(t, time.Date(2026, 11, 16, 5, 0, 0, 0, time.UTC), s.UpdatedAt)
}

// An enable time that does not read, with no item yet, shows no card rather
// than failing the Inbox.
func TestWatchmanJournalSummary_UnreadableEnableTimeIsNoCard(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	_, err := d.Exec(`INSERT OR REPLACE INTO watchman_workbenches (workbench_id, enabled_at) VALUES (1, 'yesterday')`)
	require.NoError(t, err)
	require.Nil(t, wmJournalSummary(t, d, time.UTC))
}

// A night runs from 12:00 to 12:00 in the given zone.
func TestWatchmanNightStart(t *testing.T) {
	loc := time.FixedZone("UTC+3", 3*3600)
	require.Equal(t, time.Date(2026, 11, 15, 12, 0, 0, 0, loc),
		WatchmanNightStart(time.Date(2026, 11, 16, 8, 59, 0, 0, time.UTC), loc), "11:59 local is still last night")
	require.Equal(t, time.Date(2026, 11, 16, 12, 0, 0, 0, loc),
		WatchmanNightStart(time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC), loc), "12:00 local starts tonight")
}
