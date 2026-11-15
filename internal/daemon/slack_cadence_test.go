package daemon

import (
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	gosync "sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/sync"
)

const cadenceBase = 15 * time.Minute

var cadenceT0 = time.Date(2026, 11, 15, 9, 0, 0, 0, time.UTC)

// Outcomes of one Slack run, as the cadence sees them.
var (
	run429      = sync.RunOutcome{RateLimited: true, Pages: 2, Messages: 150}
	runStorm    = sync.RunOutcome{RateLimited: true, ResumePending: true, Pages: 3, Messages: 300}
	runHeavy    = sync.RunOutcome{Pages: 7, Messages: 650}
	runQuiet    = sync.RunOutcome{Pages: 1, Messages: 2}
	runOrdinary = sync.RunOutcome{Pages: 1, Messages: 20}
	runResume   = sync.RunOutcome{ResumePending: true, Pages: 5, Messages: 500}
)

// step applies one run at now and returns the interval to the next due run.
func step(c *slackCadence, o sync.RunOutcome, now time.Time) time.Duration {
	c.after(o, cadenceBase, now)
	return c.nextDue.Sub(now)
}

func TestCadence_BacksOffOn429(t *testing.T) {
	var c slackCadence
	now := cadenceT0
	assert.Equal(t, 15*time.Minute, step(&c, runOrdinary, now))
	var got []time.Duration
	for range 3 {
		got = append(got, step(&c, run429, now))
	}
	assert.Equal(t, []time.Duration{30 * time.Minute, 60 * time.Minute, 60 * time.Minute}, got)
}

func TestCadence_RecoversWhenClean(t *testing.T) {
	c := slackCadence{level: 2}
	assert.Equal(t, 30*time.Minute, step(&c, runOrdinary, cadenceT0))
	assert.Equal(t, 15*time.Minute, step(&c, runOrdinary, cadenceT0))
	assert.Equal(t, 15*time.Minute, step(&c, runOrdinary, cadenceT0), "never below base")
}

func TestCadence_ResumeIsDueNextCycle(t *testing.T) {
	var c slackCadence
	assert.Zero(t, step(&c, runResume, cadenceT0), "a clean run with pages left is due at once")
	assert.True(t, c.due(cadenceT0.Add(time.Minute), false))
}

// A storm of 429s with pages left backs the account off to the cap instead
// of hammering: the pending resume never makes it due at once.
func TestCadence_StormBacksOffToCap(t *testing.T) {
	var c slackCadence
	now := cadenceT0
	var got []time.Duration
	for range 5 {
		d := step(&c, runStorm, now)
		assert.False(t, c.due(now.Add(d/4), false), "not due before the backed-off interval")
		got = append(got, d)
		now = now.Add(d)
		require.True(t, c.due(now, false), "due once the interval passed")
	}
	assert.Equal(t, []time.Duration{30 * time.Minute, 60 * time.Minute, 60 * time.Minute, 60 * time.Minute, 60 * time.Minute}, got)
}

func TestCadence_VolumeShortensAndQuietLengthens(t *testing.T) {
	c := slackCadence{level: 2}
	assert.Equal(t, 15*time.Minute, step(&c, runHeavy, cadenceT0), "a heavy run is back to base at once")
	var got []time.Duration
	for range 9 {
		got = append(got, step(&c, runQuiet, cadenceT0))
	}
	assert.Equal(t, []time.Duration{
		15 * time.Minute, 15 * time.Minute, 30 * time.Minute, // run 3 lengthens
		30 * time.Minute, 30 * time.Minute, 60 * time.Minute, // run 6 lengthens
		60 * time.Minute, 60 * time.Minute, 60 * time.Minute, // capped
	}, got)
	assert.Equal(t, 30*time.Minute, step(&c, runOrdinary, cadenceT0), "an ordinary run shortens one step")
}

// A 429 resets the quiet streak: the next quiet runs start a new one.
func TestCadence_429ResetsQuietStreak(t *testing.T) {
	var c slackCadence
	step(&c, runQuiet, cadenceT0)
	step(&c, runQuiet, cadenceT0)
	assert.Equal(t, 30*time.Minute, step(&c, run429, cadenceT0))
	assert.Equal(t, 30*time.Minute, step(&c, runQuiet, cadenceT0), "streak restarted: run 1 of 3")
}

func TestCadence_ManualTriggerAlwaysRuns(t *testing.T) {
	var c slackCadence
	step(&c, run429, cadenceT0)
	assert.False(t, c.due(cadenceT0.Add(time.Minute), false))
	assert.True(t, c.due(cadenceT0.Add(time.Minute), true))
}

func TestCadence_RestartRunsAtOnce(t *testing.T) {
	d := New(&config.Config{})
	assert.True(t, d.slackCadence(1).due(cadenceT0, false), "a fresh daemon runs every account")
}

// The cadence anchors on the run's start and tolerates the poll ticker
// arriving a little early: at base the next tick always runs.
func TestCadence_NextTickAtBaseRuns(t *testing.T) {
	var c slackCadence
	step(&c, runOrdinary, cadenceT0)
	assert.True(t, c.due(cadenceT0.Add(cadenceBase-time.Second), false))
	step(&c, run429, cadenceT0)
	assert.False(t, c.due(cadenceT0.Add(cadenceBase), false), "one tick of a 30-minute interval is skipped")
}

// A Slack run the cadence skips writes nothing, is no sync error and does
// not freeze the Inbox watermark: messages it stores later are detected by
// their stored time (Task 4), so the shared watermark keeps moving.
func TestPhaseSlackSync_SkippedAccountDoesNotFreezeInbox(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	mux := http.NewServeMux()
	// Retry-After 0 retries at once: the test-only unlimited limiter holds
	// nothing for an unstated Retry-After (unstatedHold = 0).
	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "0")
		w.WriteHeader(http.StatusTooManyRequests)
	})
	var searches atomic.Int32
	orch, _ := newStatusTrackingOrchestrator(t, mux, &searches)
	cfg := &config.Config{ActiveWorkspace: "ws", Sync: config.SyncConfig{PollInterval: cadenceBase}}
	d := New(cfg)
	d.SetLogger(log.New(os.Stderr, "[test-cadence] ", 0))
	d.SetOrchestrators([]*sync.Orchestrator{orch})
	d.slackCadenceBase = cadenceBase
	now := cadenceT0
	d.cadenceNow = func() time.Time { return now }
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	resultPath := filepath.Join(cfg.WorkspaceDir(), "last_sync.json")

	syncErr, inboxErr := d.phaseSlackSync(context.Background())
	require.NoError(t, syncErr)
	require.Error(t, inboxErr, "the rate-limited run freezes the Inbox (INBOX-09)")
	ran := searches.Load()
	require.NotZero(t, ran)
	require.FileExists(t, resultPath)
	require.NoError(t, os.Remove(resultPath))

	now = now.Add(cadenceBase) // the next tick: the backed-off account is not due
	syncErr, inboxErr = d.phaseSlackSync(context.Background())
	assert.NoError(t, syncErr)
	assert.NoError(t, inboxErr, "a skipped account does not freeze the Inbox")
	assert.Equal(t, ran, searches.Load(), "nothing is fetched")
	assert.NoFileExists(t, resultPath, "a skipped run writes no last_sync.json: the last one stays")

	// Sync Now always runs Slack.
	_, inboxErr = d.phaseSlackSync(withManualSync(context.Background()))
	assert.Greater(t, searches.Load(), ran)
	assert.Error(t, inboxErr)
}

// A manual trigger's cycle carries the mark that runs every Slack account;
// a scheduled cycle does not.
func TestCadence_ManualCycleMarksFetchContext(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newQuietDaemon(t)
	marks := make(chan bool, 2)
	d.SetRoutingJob(func(ctx, fetchCtx context.Context) (context.Context, context.Context) {
		marks <- isManualSync(fetchCtx)
		return ctx, fetchCtx
	})
	<-d.startManualCycle(context.Background()).done
	assert.True(t, <-marks)
	<-d.startCycle(context.Background(), true).done
	assert.False(t, <-marks)
}

// Every account's cadence is anchored at the phase's start: a slow first
// account (here a run that takes past half a base interval) does not push a
// healthy level-0 account after it off the next tick.
func TestPhaseSlackSync_SlowAccountDoesNotDelayTheNext(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	now := cadenceT0
	var mu gosync.Mutex
	inner := testMux()
	slowMux := http.NewServeMux()
	slowMux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/search.messages" {
			mu.Lock()
			now = now.Add(cadenceBase/2 + time.Minute) // the run takes long
			mu.Unlock()
		}
		inner.ServeHTTP(w, r)
	})
	var slowCount, fastCount atomic.Int32
	slow, _ := newStatusTrackingOrchestrator(t, slowMux, &slowCount)
	fast := newSecondAccountOrchestrator(t, testMux(), &fastCount)
	d := New(&config.Config{Sync: config.SyncConfig{PollInterval: cadenceBase}})
	d.SetLogger(log.New(os.Stderr, "[test-cadence] ", 0))
	d.SetOrchestrators([]*sync.Orchestrator{slow, fast})
	d.slackCadenceBase = cadenceBase
	d.cadenceNow = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }

	start := d.cadenceClock()
	syncErr, _ := d.phaseSlackSync(context.Background())
	require.NoError(t, syncErr, "both runs are clean")
	require.NotZero(t, slowCount.Load())
	require.Len(t, d.slackCadences, 2, "each account keeps its own cadence")
	ran := fastCount.Load()

	mu.Lock()
	now = start.Add(cadenceBase) // the next tick
	mu.Unlock()
	_, _ = d.phaseSlackSync(context.Background())
	assert.Greater(t, fastCount.Load(), ran, "account 2 is due on the next tick")
}

// newSecondAccountOrchestrator is newStatusTrackingOrchestrator for Slack
// account 2, so it keeps a cadence of its own next to account 1's.
func newSecondAccountOrchestrator(t *testing.T, mux *http.ServeMux, searches *atomic.Int32) *sync.Orchestrator {
	t.Helper()
	countingMux := http.NewServeMux()
	countingMux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/search.messages" {
			searches.Add(1)
		}
		mux.ServeHTTP(w, r)
	})
	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T024BE7LD", Name: "test-workspace", Domain: "test-workspace"}))
	for range 2 {
		_, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T024BE7LD", TeamName: "test-workspace", TeamDomain: "test-workspace"})
		require.NoError(t, err)
	}
	srv := httptest.NewServer(countingMux)
	t.Cleanup(srv.Close)
	orch := sync.NewOrchestrator(database, watchtowerslack.NewClientWithAPIURLUnlimited("xoxp-test-token", srv.URL+"/"),
		&config.Config{Sync: config.SyncConfig{Workers: 1, InitialHistoryDays: 1}}, 2)
	orch.SetLogger(log.New(os.Stderr, "[test-account-2] ", 0))
	return orch
}
