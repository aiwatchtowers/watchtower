package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func wmBool(b bool) *bool { return &b }

func wmSetFlags(t *testing.T, d *DB, at time.Time, fs ...WatchmanPrecedentFlags) {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.SetWatchmanPrecedentFlags(tx, fs, at))
	require.NoError(t, tx.Commit())
}

func TestWatchmanUnflagged_OnlyUnflaggedOfSources(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	for i, k := range []string{"a", "b", "c"} {
		wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: k, Category: "design",
			DecidedAt: t0.Add(time.Duration(i) * time.Hour), Weight: 1})
	}
	wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "git", SourceKey: "g", Category: "finish", DecidedAt: t0, Weight: 1})
	var id int64
	require.NoError(t, d.QueryRow(`SELECT id FROM watchman_precedents WHERE source_key = 'b'`).Scan(&id))
	wmSetFlags(t, d, t0, WatchmanPrecedentFlags{ID: id, IsDecision: wmBool(true), Parked: wmBool(false)})

	got, err := d.WatchmanUnflagged(1, []string{"ask", "turn"}, 10)
	require.NoError(t, err)
	require.Len(t, got, 2)
	require.Equal(t, "c", got[0].SourceKey) // newest first
	require.Equal(t, "a", got[1].SourceKey)
}

func TestSetWatchmanPrecedentFlags_NilKeepsNullButMarksTried(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	wmUpsert(t, d,
		WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: "a", Category: "design", DecidedAt: t0, Weight: 1},
		WatchmanPrecedent{WorkbenchID: 1, Source: "turn", SourceKey: "b", Category: "design", DecidedAt: t0, Weight: 1})
	before, err := d.WatchmanFlagsPending(1)
	require.NoError(t, err)
	require.Equal(t, 2, before)
	var id int64
	require.NoError(t, d.QueryRow(`SELECT id FROM watchman_precedents WHERE source_key = 'a'`).Scan(&id))
	wmSetFlags(t, d, t0, WatchmanPrecedentFlags{ID: id})
	after, err := d.WatchmanFlagsPending(1)
	require.NoError(t, err)
	require.Equal(t, 1, after)
	got, err := d.WatchmanBacktestCandidates(1, "design", 10)
	require.NoError(t, err)
	for _, p := range got {
		if p.ID == id {
			require.Nil(t, p.IsDecision)
			require.Nil(t, p.Parked)
		}
	}
}

func TestWatchmanBacktestCandidates_SkipsNonDecisionsAndParked(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	cases := []struct {
		key        string
		dec, parkd *bool
	}{
		{"d1p0", wmBool(true), wmBool(false)},
		{"d0p0", wmBool(false), wmBool(false)},
		{"d1p1", wmBool(true), wmBool(true)},
		{"null", nil, nil},
	}
	for i, c := range cases {
		wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: c.key, Category: "design",
			DecidedAt: t0.Add(time.Duration(i) * time.Hour), Weight: 1, IsDecision: c.dec, Parked: c.parkd})
	}
	got, err := d.WatchmanBacktestCandidates(1, "design", 10)
	require.NoError(t, err)
	require.Len(t, got, 2)
	require.Equal(t, "null", got[0].SourceKey)
	require.Equal(t, "d1p0", got[1].SourceKey)
}

func TestWatchmanUpsert_KeepsStoredFlagsWhenIncomingNil(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	p := WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: "a", Category: "design", DecidedAt: t0, Weight: 1,
		IsDecision: wmBool(false), Parked: wmBool(true)}
	wmUpsert(t, d, p)
	p.IsDecision, p.Parked = nil, nil
	p.Situation = "edited"
	wmUpsert(t, d, p)
	var dec, parked int
	var at string
	require.NoError(t, d.QueryRow(`SELECT is_decision, parked, flags_at FROM watchman_precedents`).Scan(&dec, &parked, &at))
	require.Equal(t, 0, dec)
	require.Equal(t, 1, parked)
	require.NotEmpty(t, at)
}

func TestWatchmanBacktestRow_HandedRoundTrip(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	id, err := d.InsertWatchmanBacktest(WatchmanBacktest{WorkbenchID: 1, StartedAt: t0, Status: "running"})
	require.NoError(t, err)
	require.NoError(t, d.AddWatchmanBacktestRow(id, WatchmanBacktestRow{Category: "tests", Total: 20, Handed: 4, Status: "not_measured"}))
	_, rows, err := d.WatchmanBacktestByID(1, id)
	require.NoError(t, err)
	require.Len(t, rows, 1)
	require.Equal(t, 4, rows[0].Handed)
}
