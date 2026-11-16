package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func wmTestWorkbench(t *testing.T, d *DB, id int64) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (?, 'acme', ?)`, id, "/tmp/acme-"+time.Duration(id).String())
	require.NoError(t, err)
}

func wmUpsert(t *testing.T, d *DB, ps ...WatchmanPrecedent) {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.UpsertWatchmanPrecedents(tx, ps))
	require.NoError(t, tx.Commit())
}

func TestWatchmanPrecedents_UpsertAndSearch(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	p := WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: "a1", Category: "design",
		Situation: "which cache layer should the importer use", Choice: "keep sqlite", OwnerWords: "no new dependency", DecidedAt: t0, Weight: 1}
	wmUpsert(t, d, p)
	p.Choice = "keep sqlite, no redis"
	wmUpsert(t, d, p)
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM watchman_precedents`).Scan(&n))
	require.Equal(t, 1, n)

	wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: "a2", Category: "design",
		Situation: "importer cache invalidation", Choice: "ttl", DecidedAt: t0.Add(48 * time.Hour), Weight: 1},
		WatchmanPrecedent{WorkbenchID: 1, Source: "review", SourceKey: "r1", Category: "tests",
			Situation: "importer needs a cache test", Choice: "add", DecidedAt: t0, Weight: 1})

	got, err := d.SearchWatchmanPrecedents(1, "design", "importer cache", t0.Add(72*time.Hour), nil, 10)
	require.NoError(t, err)
	require.Len(t, got, 2)
	require.Equal(t, "keep sqlite, no redis", func() string {
		for _, g := range got {
			if g.SourceKey == "a1" {
				return g.Choice
			}
		}
		return ""
	}())

	got, err = d.SearchWatchmanPrecedents(1, "design", "importer cache", t0.Add(24*time.Hour), nil, 10)
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "a1", got[0].SourceKey)

	got, err = d.SearchWatchmanPrecedents(1, "design", "importer cache", t0.Add(72*time.Hour), []int64{got[0].ID}, 10)
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "a2", got[0].SourceKey)

	// Query text with FTS syntax characters must not error.
	_, err = d.SearchWatchmanPrecedents(1, "design", `"cache" OR (x*`, t0.Add(72*time.Hour), nil, 10)
	require.NoError(t, err)
}

func TestWatchmanCursor_RoundTrip(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	c, err := d.WatchmanCursor(1, "ask")
	require.NoError(t, err)
	require.Equal(t, "", c)
	for _, v := range []string{"10", "20"} {
		tx, err := d.Begin()
		require.NoError(t, err)
		require.NoError(t, d.SetWatchmanCursor(tx, 1, "ask", v))
		require.NoError(t, tx.Commit())
	}
	c, err = d.WatchmanCursor(1, "ask")
	require.NoError(t, err)
	require.Equal(t, "20", c)
}

func TestWatchmanWorkbenches_EnableAndLearned(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmTestWorkbench(t, d, 2)
	at := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	require.NoError(t, d.EnableWatchmanWorkbench(2, at, 40))
	require.NoError(t, d.EnableWatchmanWorkbench(2, at.Add(time.Hour), 99)) // idempotent: keeps the first estimate
	ids, err := d.WatchmanWorkbenches()
	require.NoError(t, err)
	require.Equal(t, []int64{2}, ids)
	var est int
	require.NoError(t, d.QueryRow(`SELECT estimated_decisions FROM watchman_workbenches WHERE workbench_id=2`).Scan(&est))
	require.Equal(t, 40, est)
	require.NoError(t, d.MarkWatchmanLearned(2, at))
	var lt string
	require.NoError(t, d.QueryRow(`SELECT learned_through FROM watchman_workbenches WHERE workbench_id=2`).Scan(&lt))
	require.Equal(t, "2026-11-01T10:00:00Z", lt)
}

func TestWatchmanProfile_Upsert(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	at := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	require.NoError(t, d.UpsertWatchmanProfile(WatchmanProfile{WorkbenchID: 1, Key: "design", Text: "a", Version: 1, UpdatedAt: at}))
	require.NoError(t, d.UpsertWatchmanProfile(WatchmanProfile{WorkbenchID: 1, Key: "design", Text: "b", Pinned: true, Version: 2, UpdatedAt: at}))
	ps, err := d.WatchmanProfiles(1)
	require.NoError(t, err)
	require.Len(t, ps, 1)
	require.Equal(t, "b", ps[0].Text)
	require.True(t, ps[0].Pinned)
	require.Equal(t, 2, ps[0].Version)
}

func TestWatchmanBacktest_LatestRows(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	at := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	fin := at.Add(time.Minute)
	_, err := d.InsertWatchmanBacktest(WatchmanBacktest{WorkbenchID: 1, StartedAt: at, FinishedAt: &fin, Status: "done", Verdict: "stop"})
	require.NoError(t, err)
	id, err := d.InsertWatchmanBacktest(WatchmanBacktest{WorkbenchID: 1, StartedAt: at.Add(time.Hour), FinishedAt: &fin, Status: "done", Verdict: "go", CostUSD: 1.5,
		Rows: []WatchmanBacktestRow{{Category: "permission", Total: 40, Agree: 38, WrongHigh: 1, Status: "strong", CostUSD: 0.5}, {Category: "design", Total: 5, Status: "not_measured"}}})
	require.NoError(t, err)
	b, rows, err := d.LatestWatchmanBacktest(1)
	require.NoError(t, err)
	require.Equal(t, id, b.ID)
	require.Equal(t, "go", b.Verdict)
	require.Len(t, rows, 2)
	require.Equal(t, "design", rows[0].Category) // ordered by category
	require.Equal(t, 38, rows[1].Agree)

	none, nrows, err := d.LatestWatchmanBacktest(99)
	require.NoError(t, err)
	require.Nil(t, none)
	require.Empty(t, nrows)
}

func TestWatchmanBacktest_LatestDoneSkipsFailed(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	at := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	doneID, err := d.InsertWatchmanBacktest(WatchmanBacktest{WorkbenchID: 1, StartedAt: at, Status: "done", Verdict: "stop",
		Rows: []WatchmanBacktestRow{{Category: "tests", Total: 30, Agree: 20, Status: "weak"}}})
	require.NoError(t, err)
	runID, err := d.InsertWatchmanBacktest(WatchmanBacktest{WorkbenchID: 1, StartedAt: at.Add(time.Hour), Status: "running"})
	require.NoError(t, err)
	require.NoError(t, d.SetWatchmanBacktestProgress(runID, "permission 3/8"))
	b, _, err := d.LatestWatchmanBacktest(1)
	require.NoError(t, err)
	require.Equal(t, "permission 3/8", b.Progress)

	n, err := d.FailRunningWatchmanBacktests(1, "daemon restarted", at.Add(2*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 1, n)
	b, _, err = d.LatestWatchmanBacktest(1)
	require.NoError(t, err)
	require.Equal(t, "failed", b.Status)
	require.Equal(t, "daemon restarted", b.Error)
	require.NotNil(t, b.FinishedAt)

	done, rows, err := d.LatestDoneWatchmanBacktest(1)
	require.NoError(t, err)
	require.Equal(t, doneID, done.ID)
	require.Len(t, rows, 1)
}

func TestWatchmanTables_CascadeOnWorkbenchDelete(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	at := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	require.NoError(t, d.EnableWatchmanWorkbench(1, at, 3))
	wmUpsert(t, d, WatchmanPrecedent{WorkbenchID: 1, Source: "ask", SourceKey: "a1", Category: "design", Situation: "cascade word", DecidedAt: at, Weight: 1})
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.SetWatchmanCursor(tx, 1, "ask", "5"))
	require.NoError(t, tx.Commit())
	require.NoError(t, d.UpsertWatchmanProfile(WatchmanProfile{WorkbenchID: 1, Key: "design", Text: "t", Version: 1, UpdatedAt: at}))
	_, err = d.InsertWatchmanBacktest(WatchmanBacktest{WorkbenchID: 1, StartedAt: at, Status: "done", Rows: []WatchmanBacktestRow{{Category: "design", Status: "weak"}}})
	require.NoError(t, err)

	_, err = d.Exec(`DELETE FROM projects WHERE id = 1`)
	require.NoError(t, err)
	for _, tbl := range []string{"watchman_workbenches", "watchman_precedents", "watchman_cursors", "watchman_profile", "watchman_backtests", "watchman_backtest_rows"} {
		var n int
		require.NoError(t, d.QueryRow(`SELECT count(*) FROM `+tbl).Scan(&n))
		require.Zero(t, n, tbl)
	}
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM watchman_fts WHERE watchman_fts MATCH 'cascade'`).Scan(&n))
	require.Zero(t, n)
}

// Stamps in second and millisecond layouts compare by time, not as text
// ("…:56Z" sorts after "…:56.500Z" as text).
func TestWatchmanReaders_PageMixedStampLayouts(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (1, 'shell', 's', '/tmp/acme')`)
	require.NoError(t, err)
	s, _ := res.LastInsertId()
	for _, at := range []string{"2026-11-01T10:00:56Z", "2026-11-01T10:00:56.500Z", "2026-11-01T10:00:57.000Z"} {
		_, err := d.Exec(`INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, status, created_at, decided_at)
			VALUES (?, 1, 'Bash', 'allowed', ?, ?)`, s, at, at)
		require.NoError(t, err)
	}
	newest, err := d.WatchmanPermissionDecisions(1, nil, true, 10)
	require.NoError(t, err)
	require.Len(t, newest, 3)
	require.Equal(t, []string{"2026-11-01T10:00:57.000Z", "2026-11-01T10:00:56.500Z", "2026-11-01T10:00:56.000Z"},
		[]string{newest[0].Mark.At, newest[1].Mark.At, newest[2].Mark.At})

	after, err := d.WatchmanPermissionDecisions(1, &newest[2].Mark, false, 10)
	require.NoError(t, err)
	require.Len(t, after, 2)
	require.Equal(t, newest[1].ID, after[0].ID, "after-pages run oldest first")
	before, err := d.WatchmanPermissionDecisions(1, &newest[0].Mark, true, 1)
	require.NoError(t, err)
	require.Equal(t, []int64{newest[1].ID}, []int64{before[0].ID})
}
