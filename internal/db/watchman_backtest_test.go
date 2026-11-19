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
	require.NoError(t, d.AddWatchmanBacktestRow(id, WatchmanBacktestRow{Category: "tests", Total: 32, Agree: 25,
		Acceptable: 6, Bad: 1, WrongHigh: 0, Status: "strong", CostUSD: 0.5, Baseline: 0.4, RecBaseline: 0.75}))
	require.NoError(t, d.FinishWatchmanBacktest(id, "done", "stop", "", 0.5, t0.Add(time.Hour)))
	b, rows, err := d.LatestWatchmanBacktest(1)
	require.NoError(t, err)
	require.Equal(t, "done", b.Status)
	require.Equal(t, "stop", b.Verdict)
	require.InDelta(t, 0.5, b.CostUSD, 1e-9)
	require.NotNil(t, b.FinishedAt)
	require.Len(t, rows, 1)
	require.Equal(t, WatchmanBacktestRow{Category: "tests", Total: 32, Agree: 25, Acceptable: 6, Bad: 1,
		Status: "strong", CostUSD: 0.5, Baseline: 0.4, RecBaseline: 0.75}, rows[0])
	// A finished row is not reopened or rewritten.
	require.NoError(t, d.FinishWatchmanBacktest(id, "failed", "", "late", 9, t0.Add(2*time.Hour)))
	b, _, err = d.LatestWatchmanBacktest(1)
	require.NoError(t, err)
	require.Equal(t, "done", b.Status)
}

func TestWatchmanBacktestCandidates_SkipRoundsAndReverts(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	for i, k := range []string{"comment:1", "round:2", "revert:3", "lesson:4", "comment:5"} {
		wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "review", SourceKey: k, Category: "review_code",
			Situation: "s", Choice: "c", DecidedAt: t0.Add(time.Duration(i) * time.Hour), Weight: 1})
	}
	wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: "round:9", Category: "review_code",
		Situation: "s", Choice: "c", DecidedAt: t0, Weight: 1})
	got, err := d.WatchmanBacktestCandidates(1, "review_code", 10)
	require.NoError(t, err)
	var keys []string
	for _, p := range got {
		keys = append(keys, p.Source+"/"+p.SourceKey)
	}
	require.Equal(t, []string{"review/comment:5", "review/lesson:4", "ask/round:9", "review/comment:1"}, keys)
}

func TestWatchmanBacktestCandidates_SkipGit(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	wmUpsert(t, d,
		WatchmanPrecedent{WorkbenchID: 1, Source: "git", SourceKey: "merge:abc", Category: "finish",
			Situation: "PR #4: importer cache", Choice: "merged", DecidedAt: t0.Add(2 * time.Hour), Weight: 1},
		WatchmanPrecedent{WorkbenchID: 1, Source: "git", SourceKey: "commit:def", Category: "finish",
			Situation: "rewrote the agent's commit", Choice: "rewrote", DecidedAt: t0.Add(time.Hour), Weight: 1},
		WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: "7", Category: "finish",
			Situation: "ship it?", Choice: "yes", DecidedAt: t0, Weight: 1})
	got, err := d.WatchmanBacktestCandidates(1, "finish", 10)
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "ask", got[0].Source)
	// Still retrievable as earlier precedents.
	before, err := d.WatchmanPrecedentsBefore(1, "finish", t0.Add(3*time.Hour), 10)
	require.NoError(t, err)
	require.Len(t, before, 3)
}
