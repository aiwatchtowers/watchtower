package watchman

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

var updateStatus = flag.Bool("update", false, "rewrite testdata/status.json")

// noGit is a folder that is not a repository: the estimate adds no commits.
func noGit(context.Context, string, ...string) ([]byte, error) {
	return nil, errors.New("not a repository")
}

func statusOf(t *testing.T, d *db.DB, wb int64, running bool) WorkbenchStatus {
	t.Helper()
	rep, err := Status(context.Background(), d, wb, StatusOptions{Running: running, Git: noGit})
	require.NoError(t, err)
	require.True(t, rep.OK)
	require.Len(t, rep.Workbenches, 1)
	return rep.Workbenches[0]
}

func TestStatus_EmptyWorkbench(t *testing.T) {
	d, wb := learnDB(t)
	s := statusOf(t, d, wb, false)
	require.NotNil(t, s.EnabledAt)
	assert.Equal(t, "2026-11-02T09:00:00Z", *s.EnabledAt)
	assert.Equal(t, "acme", s.Name)
	assert.Len(t, s.Precedents, len(Categories))
	for _, c := range Categories {
		assert.Zero(t, s.Precedents[c], c)
	}
	assert.Len(t, s.Sources, len(statusSources))
	for _, src := range statusSources {
		assert.Equal(t, SourceStatus{}, s.Sources[src], src)
	}
	assert.Nil(t, s.Estimate)
	assert.Equal(t, &LearningStatus{Estimated: 10}, s.Learning)
	assert.Nil(t, s.Backtest)
	assert.Nil(t, s.LastDone)
	assert.False(t, s.Running)
	assert.Empty(t, s.SleepWindow)
}

func TestStatus_NotEnabledHasEstimate(t *testing.T) {
	d := openWatchmanDB(t)
	on := addWorkbench(t, d, t.TempDir())
	require.NoError(t, d.EnableWatchmanWorkbench(on, learnT0, 4))
	off := addWorkbench(t, d, t.TempDir())
	rep, err := Status(context.Background(), d, 0, StatusOptions{Git: noGit})
	require.NoError(t, err)
	require.Len(t, rep.Workbenches, 2)
	assert.Equal(t, on, rep.Workbenches[0].Workbench)
	assert.NotNil(t, rep.Workbenches[0].Learning)
	assert.Nil(t, rep.Workbenches[0].Estimate)
	assert.Equal(t, off, rep.Workbenches[1].Workbench)
	assert.Nil(t, rep.Workbenches[1].EnabledAt)
	assert.Nil(t, rep.Workbenches[1].Learning)
	assert.Equal(t, &EstimateStatus{}, rep.Workbenches[1].Estimate)
}

// A repository whose commit count runs past the timeout leaves the
// estimate null instead of holding the status up.
func TestStatus_EstimateTimesOut(t *testing.T) {
	prev := statusGitTimeout
	statusGitTimeout = 0 // the context is past its deadline at once
	t.Cleanup(func() { statusGitTimeout = prev })
	d := openWatchmanDB(t)
	off := addWorkbench(t, d, t.TempDir())
	hadDeadline := false
	git := func(ctx context.Context, _ string, _ ...string) ([]byte, error) {
		_, hadDeadline = ctx.Deadline()
		return nil, ctx.Err()
	}
	rep, err := Status(context.Background(), d, off, StatusOptions{Git: git})
	require.NoError(t, err)
	require.Len(t, rep.Workbenches, 1)
	assert.True(t, hadDeadline)
	assert.Nil(t, rep.Workbenches[0].Estimate)
	assert.Nil(t, rep.Workbenches[0].Learning)
}

func TestStatus_UnknownWorkbench(t *testing.T) {
	d := openWatchmanDB(t)
	_, err := Status(context.Background(), d, 42, StatusOptions{Git: noGit})
	require.ErrorIs(t, err, db.ErrWorkbenchNotFound)
}

func insertBacktest(t *testing.T, d *db.DB, wb int64, status string, started time.Time, finished *time.Time, rows ...db.WatchmanBacktestRow) int64 {
	t.Helper()
	b := db.WatchmanBacktest{WorkbenchID: wb, StartedAt: started, FinishedAt: finished, Status: status, Rows: rows}
	if status == "done" {
		b.Verdict, b.CostUSD = "go", 1.25
	}
	if status == "running" {
		b.Progress = "permission, 12 of 30 · 3 of 8 categories done"
	}
	id, err := d.InsertWatchmanBacktest(b)
	require.NoError(t, err)
	return id
}

func TestStatus_AfterBacktest(t *testing.T) {
	d, wb := learnDB(t)
	fin := learnT0.Add(time.Hour)
	id := insertBacktest(t, d, wb, "done", learnT0, &fin,
		db.WatchmanBacktestRow{Category: "permission", Total: 30, Agree: 27, WrongHigh: 1, Status: "strong", CostUSD: 0.5},
		db.WatchmanBacktestRow{Category: "design", Total: 4, Status: "not_measured"})
	s := statusOf(t, d, wb, false)
	require.NotNil(t, s.Backtest)
	assert.Equal(t, s.Backtest, s.LastDone)
	assert.Equal(t, id, s.Backtest.ID)
	assert.Equal(t, "done", s.Backtest.Status)
	assert.Equal(t, "go", s.Backtest.Verdict)
	require.NotNil(t, s.Backtest.FinishedAt)
	assert.Equal(t, "2026-11-02T10:00:00Z", *s.Backtest.FinishedAt)
	assert.Equal(t, []CategoryResult{
		{Category: "design", Total: 4, Status: "not_measured"},
		{Category: "permission", Total: 30, Agree: 27, WrongHigh: 1, Status: "strong", CostUSD: 0.5},
	}, s.Backtest.Categories)

	// A later failed run is the latest; the done one stays as last_done.
	fin2 := learnT0.Add(3 * time.Hour)
	b := db.WatchmanBacktest{WorkbenchID: wb, StartedAt: learnT0.Add(2 * time.Hour), FinishedAt: &fin2, Status: "failed", Error: "provider unavailable"}
	_, err := d.InsertWatchmanBacktest(b)
	require.NoError(t, err)
	s = statusOf(t, d, wb, false)
	assert.Equal(t, "failed", s.Backtest.Status)
	assert.Equal(t, "provider unavailable", s.Backtest.Error)
	assert.Equal(t, []CategoryResult{}, s.Backtest.Categories)
	assert.Equal(t, id, s.LastDone.ID)
}

func TestStatus_RunningRowWithoutLockIsInterrupted(t *testing.T) {
	d, wb := learnDB(t)
	insertBacktest(t, d, wb, "running", learnT0, nil)
	s := statusOf(t, d, wb, false)
	assert.Equal(t, BacktestInterrupted, s.Backtest.Status)
	assert.Nil(t, s.Backtest.FinishedAt)
	assert.Nil(t, s.LastDone)

	s = statusOf(t, d, wb, true)
	assert.Equal(t, "running", s.Backtest.Status)
	assert.Equal(t, "permission, 12 of 30 · 3 of 8 categories done", s.Backtest.Progress)
	assert.True(t, s.Running)
}

func TestStatus_LearningProgress(t *testing.T) {
	d, wb := learnDB(t) // estimate 10 stored at start
	ask := &listSource{name: SourceAsk, rows: listRows(wb, SourceAsk, 4, "scope")}
	turns := &listSource{name: "turn", rows: listRows(wb, "turn", 3, "")}
	lab := &fakeLabeler{label: "nonsense"} // every turn stays unlabelled

	// A budget that ends after the first batch: written grows, not done.
	o := LearnOptions{Budget: 2 * time.Minute, Now: steppingNow(), Sources: []Source{ask, turns}, Labeler: lab, BatchSize: 2}
	_, err := Learn(context.Background(), d, wb, o)
	require.NoError(t, err)
	s := statusOf(t, d, wb, false)
	assert.Equal(t, &LearningStatus{Written: 2, Estimated: 10}, s.Learning)
	assert.Equal(t, SourceStatus{Written: 2}, s.Sources[SourceAsk])

	// Unbounded: every source ends, the workbench is learned.
	o.Budget = 0
	_, err = Learn(context.Background(), d, wb, o)
	require.NoError(t, err)
	s = statusOf(t, d, wb, false)
	assert.Equal(t, &LearningStatus{Written: 4 + 3, Estimated: 10, Done: true}, s.Learning)
	assert.Equal(t, SourceStatus{Written: 4, Done: true}, s.Sources[SourceAsk])
	assert.Equal(t, SourceStatus{Written: 0, Done: true}, s.Sources["turn"])
	assert.Equal(t, 4, s.Precedents["scope"])
}

func TestStatus_SleepWindow(t *testing.T) {
	d, wb := learnDB(t)
	require.NoError(t, d.PinWatchmanProfile(wb, SleepWindowKey, "23:30-07:15", learnT0))
	s := statusOf(t, d, wb, false)
	assert.Equal(t, "23:30-07:15", s.SleepWindow)
	assert.True(t, s.SleepWindowPinned)
}

func TestLocked(t *testing.T) {
	path := LockPath(t.TempDir())
	assert.False(t, Locked(path)) // no file
	_, err := os.Stat(path)
	assert.True(t, os.IsNotExist(err), "Locked must not create the file")
	unlock, ok, err := fsutil.TryLockFile(path)
	require.NoError(t, err)
	require.True(t, ok)
	assert.True(t, Locked(path))
	unlock()
	assert.False(t, Locked(path))
}

// TestStatus_Fixture writes testdata/status.json (with -update), the shape
// the Desktop's Swift test decodes: one enabled workbench mid-learning with a
// running backtest and a done one, one Watchman is not on for.
func TestStatus_Fixture(t *testing.T) {
	d := openWatchmanDB(t)
	on := addWorkbench(t, d, "/tmp/acme-app")
	require.NoError(t, d.EnableWatchmanWorkbench(on, learnT0, 120))
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.UpsertWatchmanPrecedents(tx, append(listRows(on, SourceAsk, 3, "scope"), listRows(on, SourcePermission, 2, "permission")...)))
	require.NoError(t, d.AddWatchmanUnlabelled(tx, on, 1))
	require.NoError(t, tx.Commit())
	require.NoError(t, d.PinWatchmanProfile(on, SleepWindowKey, "23:00-07:00", learnT0))
	fin := learnT0.Add(time.Hour)
	insertBacktest(t, d, on, "done", learnT0, &fin,
		db.WatchmanBacktestRow{Category: "permission", Total: 30, Agree: 26, WrongHigh: 1, Status: "strong", CostUSD: 0.75, Baseline: 0.6})
	insertBacktest(t, d, on, "running", learnT0.Add(2*time.Hour), nil)
	off, err := d.CreateWorkbench("acme-docs", "/tmp/acme-docs")
	require.NoError(t, err)
	_ = off

	git := func(context.Context, string, ...string) ([]byte, error) { return []byte("5\n"), nil }
	rep, err := Status(context.Background(), d, 0, StatusOptions{Running: true, Git: git})
	require.NoError(t, err)
	got, err := json.MarshalIndent(rep, "", "  ")
	require.NoError(t, err)
	got = append(got, '\n')
	path := filepath.Join("testdata", "status.json")
	if *updateStatus {
		require.NoError(t, os.MkdirAll("testdata", 0o755))
		require.NoError(t, os.WriteFile(path, got, 0o600))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.JSONEq(t, string(want), string(got), "rerun with -update")
}
