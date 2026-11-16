package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/instructions"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/watchman"
)

type watchmanTestGen struct{ calls int }

func (g *watchmanTestGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return `["scope"]`, &digest.Usage{}, "", nil
}

// stubWatchman replaces the generator, git and the feed reader; it returns
// the generator and how many times the factory was asked for one.
func stubWatchman(t *testing.T) (*watchmanTestGen, *int) {
	t.Helper()
	gen, built := &watchmanTestGen{}, 0
	prevGen, prevGit, prevFeed := watchmanGeneratorFactory, watchmanGit, watchmanFeedReader
	watchmanGeneratorFactory = func(*config.Config) digest.Generator { built++; return gen }
	watchmanGit = func(context.Context, string, ...string) ([]byte, error) { return []byte("false\n"), nil }
	watchmanFeedReader = func(context.Context, *Daemon) instructions.FeedReader {
		return func(db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) { return nil, nil }
	}
	t.Cleanup(func() { watchmanGeneratorFactory, watchmanGit, watchmanFeedReader = prevGen, prevGit, prevFeed })
	return gen, &built
}

func TestPhaseWatchmanLearn_SkipsWhenNoWorkbench(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	gen, built := stubWatchman(t)
	_, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)

	d.phaseWatchmanLearn(context.Background())
	assert.Empty(t, pipelineRunNames(t, database), "no Watchman workbench: no pipeline run")
	assert.Zero(t, *built)
	assert.Zero(t, gen.calls)
}

func TestPhaseWatchmanLearn_LearnsEnabledWorkbench(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	gen, _ := stubWatchman(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, database.EnableWatchmanWorkbench(wb, time.Now(), 1))
	_, err = database.Exec(`INSERT INTO owner_asks (project_id, kind, title, payload, status, answer, answered_at)
		VALUES (?, 'question', 'Pick a cache',
			'{"focus":[],"questions":[{"id":"q1","question":"Which cache?","options":[{"label":"sqlite"},{"label":"redis"}]}],"checklist":[]}',
			'answered', '{"answers":[{"id":"q1","labels":["sqlite"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}',
			'2026-11-01T09:00:00Z')`, wb)
	require.NoError(t, err)

	d.phaseWatchmanLearn(context.Background())
	assert.Equal(t, []string{"watchman-learn"}, pipelineRunNames(t, database))
	assert.Equal(t, 1, gen.calls)
	var category string
	require.NoError(t, database.QueryRow(`SELECT category FROM watchman_precedents WHERE workbench_id = ?`, wb).Scan(&category))
	assert.Equal(t, "scope", category)
	var learned *string
	require.NoError(t, database.QueryRow(`SELECT learned_through FROM watchman_workbenches WHERE workbench_id = ?`, wb).Scan(&learned))
	assert.NotNil(t, learned, "every source is done")
}

type watchmanProfileGen struct{ calls int }

func (g *watchmanProfileGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return `{"rules": ["Prefers small steps"]}`, &digest.Usage{}, "", nil
}

func TestPhaseWatchmanProfile_WeeklyStamp(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	stubWatchman(t)
	gen := &watchmanProfileGen{}
	prev := watchmanGeneratorFactory
	watchmanGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	t.Cleanup(func() { watchmanGeneratorFactory = prev })

	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, database.EnableWatchmanWorkbench(wb, time.Now(), 5))
	seedDesignPrecedents(t, database, wb)

	d.phaseWatchmanProfile(context.Background())
	assert.Equal(t, 1, gen.calls)
	assert.Equal(t, []string{"watchman-profile"}, pipelineRunNames(t, database))
	assert.False(t, readUnixStamp(d.lastWatchmanProfilePath()).IsZero(), "the weekly stamp is written")
	profiles, err := database.WatchmanProfiles(wb)
	require.NoError(t, err)
	keys := map[string]string{}
	for _, p := range profiles {
		keys[p.Key] = p.Text
	}
	assert.Equal(t, map[string]string{"design": "Prefers small steps", "sleep_window": ""}, keys)

	d.phaseWatchmanProfile(context.Background())
	assert.Equal(t, 1, gen.calls, "within the week: no second run")
}

func TestPhaseWatchmanProfile_FailureRetriedNextDay(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	stubWatchman(t) // its generator's reply is not a profile: the category fails
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, database.EnableWatchmanWorkbench(wb, time.Now(), 5))
	seedDesignPrecedents(t, database, wb)

	d.phaseWatchmanProfile(context.Background())
	assert.True(t, readUnixStamp(d.lastWatchmanProfilePath()).IsZero())
	assert.False(t, readUnixStamp(d.lastWatchmanProfileFailedPath()).IsZero())
	d.phaseWatchmanProfile(context.Background())
	assert.Len(t, pipelineRunNames(t, database), 1, "a failed run waits a day")
}

// seedDesignPrecedents stores five design precedents: enough for a profile.
func seedDesignPrecedents(t *testing.T, database *db.DB, wb int64) {
	t.Helper()
	tx, err := database.Begin()
	require.NoError(t, err)
	var ps []db.WatchmanPrecedent
	for i := 0; i < 5; i++ {
		ps = append(ps, db.WatchmanPrecedent{WorkbenchID: wb, Source: "ask", SourceKey: string(rune('a' + i)), Category: "design",
			Situation: "s", Choice: "c", DecidedAt: time.Date(2026, 11, 1, i, 0, 0, 0, time.UTC), Weight: 1})
	}
	require.NoError(t, database.UpsertWatchmanPrecedents(tx, ps))
	require.NoError(t, tx.Commit())
}

// stubBacktestLaunch wires a fake launcher that records the workbenches.
func stubBacktestLaunch(d *Daemon) *[]int64 {
	var launched []int64
	d.SetWatchmanBacktestLaunch(func(wb int64) error { launched = append(launched, wb); return nil })
	return &launched
}

func enabledWatchmanWorkbench(t *testing.T, database *db.DB, name string) int64 {
	t.Helper()
	wb, err := database.CreateWorkbench(name, t.TempDir())
	require.NoError(t, err)
	require.NoError(t, database.EnableWatchmanWorkbench(wb, time.Now(), 0))
	require.NoError(t, database.MarkWatchmanLearned(wb, time.Now()))
	return wb
}

// A workbench still learning its history is not backtested.
func TestPhaseWatchmanBacktest_SkipsHalfLearned(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	stubWatchman(t)
	launched := stubBacktestLaunch(d)
	learning, err := database.CreateWorkbench("acme-learning", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, database.EnableWatchmanWorkbench(learning, time.Now(), 0))
	learned := enabledWatchmanWorkbench(t, database, "acme")
	d.phaseWatchmanBacktest(context.Background())
	d.phaseWatchmanBacktest(context.Background())
	assert.Equal(t, []int64{learned}, *launched)
	assert.True(t, readUnixStamp(d.watchmanBacktestLaunchedPath(learning)).IsZero(), "nothing stamped for the learning one")
}

// The weekly phase never runs a backtest in-process: it launches one
// detached child per cycle, for one due workbench, then waits a day for it.
func TestPhaseWatchmanBacktest_LaunchesDetachedOncePerCycle(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	gen, _ := stubWatchman(t)
	launched := stubBacktestLaunch(d)
	a := enabledWatchmanWorkbench(t, database, "acme")
	b := enabledWatchmanWorkbench(t, database, "acme-two")

	d.phaseWatchmanBacktest(context.Background())
	assert.Equal(t, []int64{a}, *launched, "one launch per cycle")
	d.phaseWatchmanBacktest(context.Background())
	assert.Equal(t, []int64{a, b}, *launched, "the next cycle takes the next due workbench")
	d.phaseWatchmanBacktest(context.Background())
	assert.Equal(t, []int64{a, b}, *launched, "a launched child is not relaunched within a day")
	assert.Zero(t, gen.calls, "no model call in the daemon")
	n := 0
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM watchman_backtests`).Scan(&n))
	assert.Zero(t, n, "the daemon writes no backtest row")
}

func TestPhaseWatchmanBacktest_SkipsWhenLocked(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	stubWatchman(t)
	launched := stubBacktestLaunch(d)
	wb := enabledWatchmanWorkbench(t, database, "acme")
	unlock, ok, err := fsutil.TryLockFile(watchman.LockPath(d.config.WorkspaceDir()))
	require.NoError(t, err)
	require.True(t, ok)
	d.phaseWatchmanBacktest(context.Background())
	assert.Empty(t, *launched)
	assert.True(t, readUnixStamp(d.watchmanBacktestLaunchedPath(wb)).IsZero(), "nothing stamped: the next cycle looks again")
	unlock()
	d.phaseWatchmanBacktest(context.Background())
	assert.Equal(t, []int64{wb}, *launched)
}

func TestPhaseWatchmanBacktest_PerWorkbenchStamp(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	stubWatchman(t)
	launched := stubBacktestLaunch(d)
	a := enabledWatchmanWorkbench(t, database, "acme")
	b := enabledWatchmanWorkbench(t, database, "acme-two")
	dir := d.config.WorkspaceDir()
	// a finished this week (the child's stamp); b finished 8 days ago.
	require.NoError(t, os.WriteFile(watchman.BacktestStampPath(dir, a), []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0o600))
	require.NoError(t, os.WriteFile(watchman.BacktestStampPath(dir, b),
		[]byte(strconv.FormatInt(time.Now().Add(-8*24*time.Hour).Unix(), 10)), 0o600))
	d.phaseWatchmanBacktest(context.Background())
	assert.Equal(t, []int64{b}, *launched)
	assert.NotEqual(t, filepath.Base(watchman.BacktestStampPath(dir, a)), filepath.Base(watchman.BacktestStampPath(dir, b)))
}

func TestPhaseWatchmanBacktest_FailedLaunchTriedOnceADay(t *testing.T) {
	d, database, logs := newBackfillDaemon(t)
	stubWatchman(t)
	tries := 0
	d.SetWatchmanBacktestLaunch(func(int64) error { tries++; return errors.New("no binary") })
	enabledWatchmanWorkbench(t, database, "acme")
	d.phaseWatchmanBacktest(context.Background())
	d.phaseWatchmanBacktest(context.Background())
	assert.Equal(t, 1, tries)
	assert.Equal(t, 1, strings.Count(logs.String(), "launching: no binary"))
}
