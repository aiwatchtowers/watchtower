package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestWatchmanPrecedentsBefore_StrictAndNewestFirst(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	for i, k := range []string{"a", "b", "c", "d"} {
		wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: k, Category: "design",
			Situation: "s " + k, Choice: "c", DecidedAt: t0.Add(time.Duration(i) * time.Hour), Weight: 1})
	}
	wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: "t", Category: "tests",
		Situation: "other", Choice: "c", DecidedAt: t0, Weight: 1})
	got, err := d.WatchmanPrecedentsBefore(1, "design", t0.Add(2*time.Hour), 10)
	require.NoError(t, err)
	require.Len(t, got, 2) // "c" decided exactly at the cutoff is left out
	require.Equal(t, "b", got[0].SourceKey)
	require.Equal(t, "a", got[1].SourceKey)
	got, err = d.WatchmanPrecedentsBefore(1, "design", t0.Add(24*time.Hour), 1)
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "d", got[0].SourceKey)
}

func TestWatchmanOwnerInstructionsBefore(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO owner_instructions (scope, body, updated_at) VALUES
		('session', 'old session text', '2026-10-01T10:00:00Z'),
		('procedure', 'newer procedure', '2026-11-05T10:00:00Z')`)
	require.NoError(t, err)
	got, err := d.OwnerInstructionsBefore(time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
	require.NoError(t, err)
	require.Equal(t, OwnerInstructions{Session: "old session text"}, got)
}

func TestWatchmanBacktest_AddRowAndFinish(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	id, err := d.InsertWatchmanBacktest(WatchmanBacktest{WorkbenchID: 1, StartedAt: t0, Status: "running"})
	require.NoError(t, err)
	require.NoError(t, d.AddWatchmanBacktestRow(id, WatchmanBacktestRow{Category: "tests", Total: 30, Agree: 25, Status: "strong", CostUSD: 0.5}))
	require.NoError(t, d.FinishWatchmanBacktest(id, "done", "stop", "", 0.5, t0.Add(time.Hour)))
	b, rows, err := d.LatestWatchmanBacktest(1)
	require.NoError(t, err)
	require.Equal(t, "done", b.Status)
	require.Equal(t, "stop", b.Verdict)
	require.InDelta(t, 0.5, b.CostUSD, 1e-9)
	require.NotNil(t, b.FinishedAt)
	require.Len(t, rows, 1)
	require.Equal(t, 25, rows[0].Agree)
	// A finished row is not reopened or rewritten.
	require.NoError(t, d.FinishWatchmanBacktest(id, "failed", "", "late", 9, t0.Add(2*time.Hour)))
	b, _, err = d.LatestWatchmanBacktest(1)
	require.NoError(t, err)
	require.Equal(t, "done", b.Status)
}
