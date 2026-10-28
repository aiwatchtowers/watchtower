package daemon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	gosync "sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// loopWait bounds every wait for a loop event: generous for a loaded or -race
// runner, never reached when the loop works.
const loopWait = 10 * time.Second

// lockedLog is a goroutine-safe log sink: the cycle goroutine and the loop
// both write to the daemon logger.
type lockedLog struct {
	mu  gosync.Mutex
	buf bytes.Buffer
}

func (l *lockedLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

func (l *lockedLog) count(s string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Count(l.buf.String(), s)
}

// eventually waits, bounded by loopWait, until cond holds — for a loop
// side effect (a log line) written after the loop took the event.
func eventually(t *testing.T, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(loopWait)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(time.Millisecond)
	}
}

// waitLog waits until line has been logged n times in all.
func (l *lockedLog) waitLog(t *testing.T, line string, n int) {
	t.Helper()
	eventually(t, func() bool { return l.count(line) >= n }, "log line "+strconv.Quote(line))
}

// cycleProbe is an IMAP syncer that reports each cycle reaching it and, while
// block is set, holds the cycle there until its context is cancelled — a
// request hung on a socket a sleep killed — or release lets it go. With hold
// set, a cancelled Sync also waits for a receive on hold before it returns,
// so the test can act while the cancelled cycle is still running.
type cycleProbe struct {
	started   chan time.Time // one send per Sync
	cancelled chan struct{}  // one send per blocked Sync whose ctx was cancelled
	release   chan struct{}  // a send ends one blocked Sync normally
	hold      chan struct{}  // nil = a cancelled Sync returns at once
	block     atomic.Bool
	onSync    func() // run at the start of each Sync, nil = nothing
	// fetchRange is FetchRange's body (the history backfill's fetch), nil =
	// nothing to fetch.
	fetchRange func(ctx context.Context) error
}

func newCycleProbe() *cycleProbe {
	return &cycleProbe{started: make(chan time.Time, 16), cancelled: make(chan struct{}, 16), release: make(chan struct{})}
}

func (p *cycleProbe) Sync(ctx context.Context) (int, error) {
	if p.onSync != nil {
		p.onSync()
	}
	// Read before the started send: a test clears block right after it
	// receives that send, for the next cycle, not this one.
	blocked := p.block.Load()
	p.started <- time.Now()
	if !blocked {
		return 0, nil
	}
	select {
	case <-ctx.Done():
		p.cancelled <- struct{}{}
		if p.hold != nil {
			<-p.hold
		}
		return 0, ctx.Err()
	case <-p.release:
		return 0, nil
	}
}

func (p *cycleProbe) FetchRange(ctx context.Context, _, _ time.Time) (int, error) {
	if p.fetchRange == nil {
		return 0, nil
	}
	return 0, p.fetchRange(ctx)
}

func (p *cycleProbe) AccountID() int64                 { return 1 }
func (p *cycleProbe) FirstSyncFrom() (time.Time, bool) { return time.Time{}, false }

// setWakeSettle sets wakeSettleDelay for one test.
func setWakeSettle(t *testing.T, d time.Duration) {
	t.Helper()
	prev := wakeSettleDelay
	wakeSettleDelay = d
	t.Cleanup(func() { wakeSettleDelay = prev })
}

// countDrops counts dropConnections calls for one test. Call it before
// startLoop, so the loop has stopped before the cleanup restores the var.
func countDrops(t *testing.T) *atomic.Int32 {
	t.Helper()
	var n atomic.Int32
	prev := dropConnections
	dropConnections = func() { n.Add(1) }
	t.Cleanup(func() { dropConnections = prev })
	return &n
}

// shortenWakeSettle keeps a wake-driven test from waiting the real delay.
func shortenWakeSettle(t *testing.T) {
	t.Helper()
	setWakeSettle(t, 10*time.Millisecond)
}

// fakeMono is runLoop's monotonic clock in a test, moved by hand: it moves
// only by awake time, so a test models a sleep by not advancing it.
type fakeMono struct{ elapsed atomic.Int64 }

func (m *fakeMono) now() time.Duration       { return time.Duration(m.elapsed.Load()) }
func (m *fakeMono) advance(by time.Duration) { m.elapsed.Add(int64(by)) }

// loopHarness is a running daemon loop with a probe in its source-sync
// section, injected wake and trigger channels and a fake monotonic clock.
type loopHarness struct {
	d       *Daemon
	probe   *cycleProbe
	wake    chan time.Duration
	trigger chan struct{} // unbuffered: a send returns once the loop took it
	mono    *fakeMono
	logs    *lockedLog
	cancel  context.CancelFunc
	done    chan error
}

// loopOpts configures startLoop. The zero value: sync_on_wake off, a
// buffered wake channel, a first cycle that does not block, an hour-long poll.
type loopOpts struct {
	syncOnWake bool
	wake       chan time.Duration // nil = buffered, capacity 1
	blockFirst bool
	hold       bool          // cancelled Syncs wait for probe.hold
	poll       time.Duration // 0 = an hour
	// backfill gives the daemon a test DB with a running IMAP history
	// backfill row for the probe's account, whose fetch is fetchRange.
	backfill   bool
	fetchRange func(ctx context.Context) error
	withDB     bool // a test DB and a workspace, no backfill row (implied by backfill)
}

func startLoop(t *testing.T, o loopOpts) *loopHarness {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	if o.wake == nil {
		o.wake = make(chan time.Duration, 1)
	}
	if o.poll == 0 {
		o.poll = time.Hour
	}
	cfg := &config.Config{Sync: config.SyncConfig{PollInterval: o.poll, SyncOnWake: o.syncOnWake}}
	d := newDaemon(nil, cfg)
	logs := &lockedLog{}
	d.SetLogger(log.New(logs, "", 0))
	switch {
	case o.backfill:
		seedLoopBackfill(t, d)
	case o.withDB:
		d.SetDB(newLoopDB(t, d))
	}
	probe := newCycleProbe()
	probe.fetchRange = o.fetchRange
	probe.block.Store(o.blockFirst)
	if o.hold {
		probe.hold = make(chan struct{})
	}
	d.imapSyncers = []mailSyncer{probe}
	d.wakeCh = o.wake
	trigger := make(chan struct{})
	d.triggerCh = trigger
	mono := &fakeMono{}
	d.loopMono = mono.now

	ctx, cancel := context.WithCancel(context.Background())
	h := &loopHarness{d: d, probe: probe, wake: o.wake, trigger: trigger, mono: mono, logs: logs, cancel: cancel, done: make(chan error, 1)}
	go func() { h.done <- d.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		if probe.hold != nil {
			close(probe.hold)
		}
		select {
		case <-h.done:
		case <-time.After(loopWait):
			t.Error("daemon did not stop")
		}
	})
	return h
}

// seedLoopBackfill gives d a test DB and a workspace with one running IMAP
// history backfill row for the probe's account (id 1).
func seedLoopBackfill(t *testing.T, d *Daemon) {
	t.Helper()
	d.config.Sync.BackfillDays = 30
	database := newLoopDB(t, d)
	acct, err := database.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	require.Equal(t, int64(1), acct, "the probe's account")
	now := time.Now()
	_, err = database.StartHistoryBackfill("imap", acct, float64(now.AddDate(0, 0, -30).Unix()),
		float64(now.AddDate(0, 0, -3).Unix()), now)
	require.NoError(t, err)
	d.SetDB(database)
}

// newLoopDB gives d's config a workspace and returns a test DB for d. It is
// file-backed, as the daemon's is: a sleep cancels queries mid-flight, the
// driver then drops the pool's connection, and an in-memory database would
// come back empty on the next one.
func newLoopDB(t *testing.T, d *Daemon) *db.DB {
	t.Helper()
	d.config.ActiveWorkspace = "test-ws"
	require.NoError(t, os.MkdirAll(d.config.WorkspaceDir(), 0o755))
	database, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

// stop cancels the daemon and requires Run to return promptly.
func (h *loopHarness) stop(t *testing.T) {
	t.Helper()
	h.cancel()
	select {
	case err := <-h.done:
		require.NoError(t, err)
		h.done <- nil // for the cleanup
	case <-time.After(loopWait):
		t.Fatal("daemon did not stop after cancellation")
	}
}

// letGo ends the held cancelled Sync (loopOpts.hold).
func (h *loopHarness) letGo(t *testing.T) {
	t.Helper()
	select {
	case h.probe.hold <- struct{}{}:
	case <-time.After(loopWait):
		t.Fatal("no cancelled Sync is held")
	}
}

func recv[T any](t *testing.T, ch <-chan T, what string) T {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(loopWait):
		t.Fatalf("timed out waiting for %s", what)
		var zero T
		return zero
	}
}

// requireNone asserts nothing arrives on ch within d — for "no new cycle".
func requireNone[T any](t *testing.T, ch <-chan T, d time.Duration, what string) {
	t.Helper()
	select {
	case <-ch:
		t.Fatalf("unexpected %s", what)
	case <-time.After(d):
	}
}

// Log lines the loop tests wait on.
const (
	logSleepCancels   = "cancelling the running cycle's source syncs"
	logSleptCycleEnds = "cycle ended after a sleep"
	logSkipsForSleep  = "source syncs stopped by sleep, skipping pipelines"
	logQueuedFetching = "manual sync trigger received during the cycle's source syncs, syncing after it"
	logQueuedSettling = "manual sync trigger received during the post-wake wait, syncing after it"
	logRestarts       = "without Slack sync progress, cancelling the source syncs and syncing afresh"
)

// A sleep detected while a cycle hangs in its source syncs cancels them, the
// cycle skips its pipelines, the pooled connections are dropped at once, and
// a fresh cycle starts once the settle delay has passed.
func TestRunLoop_SleepCancelsRunningCycleAndStartsAFreshOne(t *testing.T) {
	const settle = 50 * time.Millisecond
	setWakeSettle(t, settle)
	drops := countDrops(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wake <- 20 * time.Minute
	recv(t, h.probe.cancelled, "the running cycle's cancellation")
	cancelledAt := time.Now()

	restartedAt := recv(t, h.probe.started, "a fresh cycle after the wake")
	assert.GreaterOrEqual(t, restartedAt.Sub(cancelledAt), settle, "the fresh cycle waits out the settle delay")
	h.stop(t)

	assert.Equal(t, 1, h.logs.count("sleep detected (slept ~20m0s), "+logSleepCancels))
	assert.Equal(t, 1, h.logs.count("skipping pipelines"), "only the cancelled cycle skips its pipelines")
	assert.Equal(t, 1, h.logs.count(logSkipsForSleep), "the skip names the sleep")
	assert.Equal(t, int32(1), drops.Load(), "the sleep drops the pooled connections")
}

// The cancel does not depend on sync.sync_on_wake; only the fresh cycle does:
// with it off, the wake starts no cycle and the next tick runs one.
func TestRunLoop_SleepCancelsCycleWithSyncOnWakeOff(t *testing.T) {
	shortenWakeSettle(t)
	h := startLoop(t, loopOpts{blockFirst: true, poll: 300 * time.Millisecond})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wake <- 5 * time.Minute
	recv(t, h.probe.cancelled, "the running cycle's cancellation")
	h.logs.waitLog(t, logSleptCycleEnds, 1)
	recv(t, h.probe.started, "the next tick's cycle")
	h.stop(t)
	assert.Zero(t, h.logs.count("syncing after wake"), "the wake itself starts no cycle with sync_on_wake off")
}

// Another wake inside the settle delay starts the delay over and drops the
// connections again.
func TestRunLoop_SleepDuringSettleRestartsTheDelay(t *testing.T) {
	const settle = 400 * time.Millisecond
	setWakeSettle(t, settle)
	drops := countDrops(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, logSleptCycleEnds, 1) // the delay is counting down
	secondWake := time.Now()
	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, "post-wake wait over", 1)

	restartedAt := recv(t, h.probe.started, "the cycle after the wakes")
	assert.GreaterOrEqual(t, restartedAt.Sub(secondWake), settle, "the second wake restarts the settle delay")
	h.stop(t)
	assert.Equal(t, int32(2), drops.Load(), "each sleep drops the pooled connections")
}

// A sleep detected while the cycle runs its pipelines never cuts them off
// (they run on the daemon's context): the cycle finishes them, and a fresh
// one follows the settle delay. The cycle here genuinely reaches its
// pipelines — the agent coach's proposing step, near the end, holds it
// there. The backfill after the pipelines is skipped (the fetch context is
// cancelled, TestOnSleep_Paths).
func TestRunLoop_SleepDuringPipelinesLetsThemFinish(t *testing.T) {
	shortenWakeSettle(t)
	drops := countDrops(t)
	inPipeline := make(chan context.Context, 1)
	finish := make(chan struct{})
	var mined, calls atomic.Int32
	prev := runCoachProposer
	runCoachProposer = func(ctx context.Context, _ *coach.Proposer, _ coach.Inputs) (int, *digest.Usage, error) {
		// Only the first call is the cycle under test; the coach's weekly
		// stamp keeps later cycles out, and a stray call is not counted.
		if calls.Add(1) > 1 {
			return 0, nil, nil
		}
		inPipeline <- ctx
		select {
		case <-finish:
			mined.Add(1)
		case <-ctx.Done(): // shutdown, only on a failed test
		}
		return 0, nil, ctx.Err()
	}
	t.Cleanup(func() { runCoachProposer = prev })
	h := startLoop(t, loopOpts{syncOnWake: true, withDB: true})

	recv(t, h.probe.started, "the initial cycle")
	pipelineCtx := recv(t, inPipeline, "the cycle's last pipeline")
	require.Equal(t, sectionPipelines, h.d.section())
	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, "during the cycle's pipelines, letting them finish", 1)
	assert.Equal(t, int32(1), drops.Load(), "the idle connections are dropped at once")
	require.NoError(t, pipelineCtx.Err(), "a sleep never cancels a running pipeline")

	requireNone(t, h.probe.started, 50*time.Millisecond, "a cycle before the running one returned")
	assert.Zero(t, h.logs.count(logSleptCycleEnds), "the loop waits for the pipelines")
	close(finish)
	h.logs.waitLog(t, logSleptCycleEnds, 1)
	recv(t, h.probe.started, "the cycle after the wake")
	h.stop(t)

	assert.Equal(t, int32(1), mined.Load(), "the pipeline ran to its end")
	// The cycle after the wake may skip its pipelines on the shutdown.
	assert.Zero(t, h.logs.count(logSkipsForSleep), "the slept cycle did not skip its pipelines")
	var firstErr string
	require.NoError(t, h.d.db.QueryRow(`SELECT COALESCE(error_msg, '') FROM pipeline_runs
		WHERE pipeline = 'coach' ORDER BY id LIMIT 1`).Scan(&firstErr))
	assert.Empty(t, firstErr, "the pipeline's run is recorded without an error")
}

// Shutdown mid-cycle: Run waits for the cycle to stop and starts no other.
func TestRunLoop_ShutdownDuringCycleStartsNoNewOne(t *testing.T) {
	shortenWakeSettle(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.stop(t)
	recv(t, h.probe.cancelled, "the cycle's cancellation")
	requireNone(t, h.probe.started, 100*time.Millisecond, "cycle after shutdown")
	assert.Equal(t, 1, h.logs.count("source syncs stopped by shutdown, skipping pipelines"))
}

// Shutdown inside the settle delay returns at once and starts no cycle.
func TestRunLoop_ShutdownDuringSettleStartsNoCycle(t *testing.T) {
	setWakeSettle(t, time.Hour)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, logSleptCycleEnds, 1)
	h.stop(t)
	requireNone(t, h.probe.started, 100*time.Millisecond, "cycle after shutdown")
}

// pressSyncNow sends a manual trigger and returns once the loop has logged
// line for it — the loop logs after it took the send, so the send returning
// is not enough.
func (h *loopHarness) pressSyncNow(t *testing.T, line string) {
	t.Helper()
	before := h.logs.count(line)
	h.trigger <- struct{}{}
	h.logs.waitLog(t, line, before+1)
}

// releaseProbe ends the blocked Sync normally; it fails, rather than hangs,
// when no Sync is blocked (the cycle was cancelled after all).
func (h *loopHarness) releaseProbe(t *testing.T) {
	t.Helper()
	select {
	case h.probe.release <- struct{}{}:
	case <-time.After(loopWait):
		t.Fatal("no blocked Sync to release: the cycle did not run on")
	}
}

// inSlackSync marks the cycle blocked in the probe as in its Slack sync: the
// probe, an IMAP syncer, stands in for a Slack sync hung on a dead socket.
func (h *loopHarness) inSlackSync() { h.d.setSection(sectionSlackFetch) }

// Sync Now while a cycle's Slack sync has made no progress for
// manualRestartAfter cancels the source syncs and starts a fresh cycle at
// once — no post-wake delay.
func TestRunLoop_TriggerOnStalledSlackSyncRestartsTheCycle(t *testing.T) {
	setWakeSettle(t, time.Hour)
	drops := countDrops(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.inSlackSync()
	h.mono.advance(manualRestartAfter)
	h.trigger <- struct{}{}
	recv(t, h.probe.cancelled, "the stalled cycle's cancellation")
	recv(t, h.probe.started, "the fresh cycle")
	h.stop(t)

	assert.Equal(t, int32(1), drops.Load(), "the pooled connections are dropped before the fresh cycle")
	assert.Equal(t, 1, h.logs.count("manual sync trigger received after 1m0s "+logRestarts))
	assert.Equal(t, 1, h.logs.count("source syncs stopped by Sync Now restart, skipping pipelines"))
}

// Sync Now on an old cycle whose Slack sync still makes progress (a long
// first sync) is queued: the cycle finishes and one more runs right after it.
func TestRunLoop_TriggerOnMovingSlackSyncWaitsForTheCycle(t *testing.T) {
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.inSlackSync()
	h.mono.advance(10 * manualRestartAfter)
	h.d.markFetchProgress() // as the Slack heartbeat does when its counters move
	h.mono.advance(manualRestartAfter - time.Second)
	h.pressSyncNow(t, logQueuedFetching)
	assert.Zero(t, h.logs.count("afresh"), "a cycle still making progress is not cancelled")

	h.releaseProbe(t)
	recv(t, h.probe.started, "the queued cycle")
	h.stop(t)
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
}

// Sync Now long into a Slack read-state pass — one conversations.info per
// channel, minutes at the rate limit, no Progress counter moving — is queued
// while Slack keeps answering: the heartbeat stamps every answered call.
func TestRunLoop_TriggerDuringMovingReadStatePassWaitsForTheCycle(t *testing.T) {
	prev := syncHeartbeatInterval
	syncHeartbeatInterval = 2 * time.Millisecond
	t.Cleanup(func() { syncHeartbeatInterval = prev })
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})
	orch, _, client := newTestOrchestratorWithClient(t, new(atomic.Int32))

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.inSlackSync()
	stopBeat := h.d.startSyncHeartbeat(orch)
	for range 3 {
		h.mono.advance(manualRestartAfter)
		_, _ = client.GetChannelReadCursor(context.Background(), "C001")
		eventually(t, func() bool { return h.d.fetchStalledFor() == 0 }, "a beat stamping the answered call")
		h.pressSyncNow(t, logQueuedFetching)
	}
	stopBeat()
	assert.Zero(t, h.logs.count("afresh"), "a pass Slack keeps answering is not restarted")

	h.releaseProbe(t)
	recv(t, h.probe.started, "the queued cycle")
	h.stop(t)
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
}

// Sync Now within manualRestartAfter of the cycle's start is queued: the
// cycle finishes and one more runs right after it.
func TestRunLoop_TriggerEarlyInSourceSyncsWaitsForTheCycle(t *testing.T) {
	drops := countDrops(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.inSlackSync()
	h.mono.advance(manualRestartAfter - time.Second)
	h.pressSyncNow(t, logQueuedFetching)
	h.pressSyncNow(t, logQueuedFetching)
	assert.Zero(t, h.logs.count("afresh"), "a young cycle is not cancelled")

	h.releaseProbe(t)
	recv(t, h.probe.started, "the queued cycle")
	requireNone(t, h.probe.started, 100*time.Millisecond, "a second queued cycle: triggers collapse into one")
	h.stop(t)
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
	assert.Zero(t, drops.Load(), "a queued trigger leaves the connections alone")
}

// Sync Now during a source fetch after the Slack sync (calendars, mail, Jira,
// Linear, Confluence: 30 s client timeouts, no in-phase progress) is queued
// however long ago the last progress stamp was.
func TestRunLoop_TriggerOnOtherFetchWaitsForTheCycle(t *testing.T) {
	drops := countDrops(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	require.Equal(t, sectionOtherFetch, h.d.section(), "the IMAP probe runs after the Slack sync")
	h.mono.advance(10 * manualRestartAfter)
	h.pressSyncNow(t, logQueuedFetching)
	assert.Zero(t, h.logs.count("afresh"), "only a stalled Slack sync is restarted")

	h.releaseProbe(t)
	recv(t, h.probe.started, "the queued cycle")
	h.stop(t)
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
	assert.Zero(t, drops.Load(), "a queued trigger leaves the connections alone")
}

// Sync Now right after the Mac woke, before the wake watcher reported the
// sleep, is queued: the stall is measured in awake time, so the half hour the
// Mac slept through a Slack sync is no stall. The wake report then cancels
// the cycle as a sleep.
func TestRunLoop_TriggerAfterSleepBeforeTheWakeReportIsQueued(t *testing.T) {
	shortenWakeSettle(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.inSlackSync()
	h.mono.advance(5 * time.Second) // awake time; the 30-minute sleep moves only the wall clock
	h.pressSyncNow(t, logQueuedFetching)
	assert.Zero(t, h.logs.count("afresh"), "the sleep is not a stall")

	h.wake <- 30 * time.Minute
	recv(t, h.probe.cancelled, "the sleep's cancellation")
	h.logs.waitLog(t, logSleptCycleEnds, 1)
	recv(t, h.probe.started, "the cycle after the delay")
	h.stop(t)
	assert.Zero(t, h.logs.count("Sync Now restart"), "the cycle was cancelled by the sleep, not restarted")
}

// Sync Now while the cycle runs its pipelines is queued whatever its stall:
// the sources are already fetched.
func TestRunLoop_TriggerDuringPipelinesWaitsForTheCycle(t *testing.T) {
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.d.setSection(sectionPipelines) // as runSync marks it past the source syncs
	h.mono.advance(10 * manualRestartAfter)
	h.pressSyncNow(t, "during the cycle's pipelines, syncing after it")
	assert.Zero(t, h.logs.count("afresh"), "a cycle in its pipelines is not cancelled")

	h.releaseProbe(t)
	recv(t, h.probe.started, "the queued cycle")
	h.stop(t)
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
}

// The history backfill runs on the cycle's fetch context: Sync Now during it
// is queued however long it runs (its 5-minute budget bounds the wait), a
// sleep cancels it, and the cancelled chunk is no strike and leaves no error
// on the history-backfill row.
func TestRunLoop_BackfillQueuesTriggersAndSleepCancelsIt(t *testing.T) {
	shortenWakeSettle(t)
	inFetch := make(chan struct{}, 1)
	var fetched atomic.Bool
	h := startLoop(t, loopOpts{syncOnWake: true, backfill: true, fetchRange: func(ctx context.Context) error {
		if fetched.Swap(true) {
			return nil // the later cycles' chunks fetch at once
		}
		inFetch <- struct{}{}
		<-ctx.Done()
		return ctx.Err()
	}})

	recv(t, h.probe.started, "the initial cycle")
	recv(t, inFetch, "the backfill's fetch")
	require.Equal(t, sectionBackfill, h.d.section())
	h.mono.advance(10 * manualRestartAfter)
	h.pressSyncNow(t, "manual sync trigger received during the history backfill, syncing after it")
	assert.Zero(t, h.logs.count("afresh"), "a trigger never cancels the backfill")

	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, "cancelling the running cycle's history backfill", 1)
	h.logs.waitLog(t, logSleptCycleEnds, 1)
	recv(t, h.probe.started, "the cycle after the delay")
	h.stop(t)
	assert.Equal(t, 1, h.logs.count("history backfill: stopped by sleep"))

	rows, err := h.d.db.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Zero(t, rows[0].ChunkFailures, "a cancelled chunk is no strike")
	assert.Nil(t, rows[0].HeldSince, "a cancelled chunk is no hold")
	var errored int
	require.NoError(t, h.d.db.QueryRow(`SELECT COUNT(*) FROM pipeline_runs
		WHERE pipeline = 'history-backfill' AND COALESCE(error_msg, '') != ''`).Scan(&errored))
	assert.Zero(t, errored, "a cancelled Step leaves no error row")
}

// A sleep that lands after Sync Now restarted the cycle, before it returned,
// does not lose the restart: the fresh cycle runs after the settle delay even
// with sync_on_wake off.
func TestRunLoop_RestartThenSleepStillSyncsAfterTheDelay(t *testing.T) {
	shortenWakeSettle(t)
	h := startLoop(t, loopOpts{blockFirst: true, hold: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.inSlackSync()
	h.mono.advance(manualRestartAfter)
	h.trigger <- struct{}{}
	recv(t, h.probe.cancelled, "the restart's cancellation")
	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, logSleepCancels, 1)
	h.letGo(t)

	h.logs.waitLog(t, logSleptCycleEnds, 1)
	recv(t, h.probe.started, "the restarted cycle after the delay")
	h.stop(t)
}

// A trigger queued during a cycle a sleep then cancels runs after the settle
// delay, sync_on_wake off.
func TestRunLoop_TriggerQueuedBeforeSleepRunsAfterTheDelay(t *testing.T) {
	shortenWakeSettle(t)
	h := startLoop(t, loopOpts{blockFirst: true, hold: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.pressSyncNow(t, logQueuedFetching)
	h.wake <- 10 * time.Minute
	recv(t, h.probe.cancelled, "the sleep's cancellation")
	h.letGo(t)

	h.logs.waitLog(t, logSleptCycleEnds, 1)
	recv(t, h.probe.started, "the queued cycle after the delay")
	h.stop(t)
	assert.Equal(t, 1, h.logs.count("syncing after wake"))
}

// Sync Now during the settle delay is folded into the one cycle the delay
// ends with: exactly one cycle, sync_on_wake on or off.
func TestRunLoop_TriggerDuringSettleRunsOneCycleAfterIt(t *testing.T) {
	for _, syncOnWake := range []bool{true, false} {
		t.Run(fmt.Sprintf("sync_on_wake=%v", syncOnWake), func(t *testing.T) {
			const settle = 200 * time.Millisecond
			setWakeSettle(t, settle)
			h := startLoop(t, loopOpts{syncOnWake: syncOnWake, blockFirst: true})

			recv(t, h.probe.started, "the initial cycle")
			h.probe.block.Store(false)
			h.wake <- 10 * time.Minute
			h.logs.waitLog(t, logSleptCycleEnds, 1)
			h.pressSyncNow(t, logQueuedSettling)
			h.pressSyncNow(t, logQueuedSettling)

			recv(t, h.probe.started, "the cycle after the delay")
			requireNone(t, h.probe.started, settle, "a second cycle")
			h.stop(t)
		})
	}
}

// runSync moves the section marker along: the fetches after the Slack sync
// are not the Slack sync (a trigger never restarts them), and the pipelines
// are marked before they run.
func TestRunSync_MarksTheSections(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newDaemon(nil, &config.Config{})
	d.SetLogger(log.New(&lockedLog{}, "", 0))
	d.setSection(sectionPipelines) // left over from the previous cycle
	probe := newCycleProbe()
	var duringSync atomic.Int32
	probe.onSync = func() { duringSync.Store(int32(d.section())) }
	d.imapSyncers = []mailSyncer{probe}

	d.runSync(context.Background(), context.Background())
	assert.Equal(t, sectionOtherFetch, cycleSection(duringSync.Load()), "the IMAP sync runs in the other-fetch section")
	assert.Equal(t, sectionPipelines, d.section(), "the pipelines section is marked")
}

// A cancelled fetch context skips the pipelines, and the log names why.
func TestRunSync_CancelledFetchSkipsPipelinesNamingTheCause(t *testing.T) {
	for _, tc := range []struct {
		name   string
		cancel func(parent context.CancelFunc, fetch context.CancelCauseFunc)
		want   string
	}{
		{"sleep", func(_ context.CancelFunc, f context.CancelCauseFunc) { f(errCycleSlept) }, "sleep"},
		{"restart", func(_ context.CancelFunc, f context.CancelCauseFunc) { f(errCycleRestart) }, "Sync Now restart"},
		{"shutdown", func(p context.CancelFunc, _ context.CancelCauseFunc) { p() }, "shutdown"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			d := newDaemon(nil, &config.Config{})
			logs := &lockedLog{}
			d.SetLogger(log.New(logs, "", 0))
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			fetchCtx, cancelFetch := context.WithCancelCause(ctx)
			defer cancelFetch(nil)
			tc.cancel(cancel, cancelFetch)

			d.runSync(ctx, fetchCtx)
			assert.Equal(t, 1, logs.count("source syncs stopped by "+tc.want+", skipping pipelines"))
		})
	}
}

// isLoopCancelErr accepts only the daemon's own cancels — the loop's (a
// sleep, a Sync Now restart) and the shutdown, also seen through a child
// context with a budget — and never a deadline, the budget's own or a
// call's, nor a real error joined with a cancel.
func TestIsLoopCancelErr(t *testing.T) {
	cancelled := func(cause error) context.Context {
		parent, cancel := context.WithCancel(context.Background())
		fetchCtx, cancelFetch := context.WithCancelCause(parent)
		t.Cleanup(func() { cancelFetch(nil) })
		bctx, cancelBudget := context.WithTimeout(fetchCtx, time.Hour) // the backfill's budget ctx
		t.Cleanup(cancelBudget)
		if cause == nil {
			cancel() // the shutdown
		} else {
			cancelFetch(cause)
			cancel()
		}
		return bctx
	}
	expired, cancelExpired := context.WithTimeout(context.Background(), -time.Second)
	defer cancelExpired()
	wrapped := fmt.Errorf("people: %w", context.Canceled)
	for _, tc := range []struct {
		name string
		ctx  context.Context
		err  error
		want bool
	}{
		{"sleep", cancelled(errCycleSlept), wrapped, true},
		{"restart", cancelled(errCycleRestart), context.Canceled, true},
		{"shutdown", cancelled(nil), wrapped, true},
		{"joined cancels", cancelled(errCycleSlept), errors.Join(context.Canceled, wrapped), true},
		{"no error", cancelled(errCycleSlept), nil, false},
		{"live ctx", context.Background(), context.Canceled, false},
		{"budget deadline", expired, context.DeadlineExceeded, false},
		{"a call's timeout under a sleep", cancelled(errCycleSlept), fmt.Errorf("gen: %w", context.DeadlineExceeded), false},
		{"real error joined", cancelled(errCycleSlept), errors.Join(context.Canceled, errors.New("disk full")), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, isLoopCancelErr(tc.ctx, tc.err))
		})
	}
}

// startCycle resets the section marker and the progress stamp on the loop
// goroutine, before the cycle's goroutine runs: a trigger right after it
// never reads the previous cycle's state. The cycle may already have moved
// on to its other fetches (no Slack orchestrator here), but it blocks in the
// IMAP probe, so it never reaches its pipelines: a pipelines section or a
// stall read right after startCycle is the previous cycle's.
func TestStartCycle_ResetsTheCycleStateFirst(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newDaemon(nil, &config.Config{})
	d.SetLogger(log.New(&lockedLog{}, "", 0))
	mono := &fakeMono{}
	d.loopMono = mono.now
	probe := newCycleProbe()
	probe.block.Store(true)
	d.imapSyncers = []mailSyncer{probe}
	d.setSection(sectionPipelines)
	d.markFetchProgress()
	mono.advance(time.Hour)

	c := d.startCycle(context.Background(), true)
	assert.Contains(t, []cycleSection{sectionSlackFetch, sectionOtherFetch}, d.section(),
		"no previous cycle's section")
	assert.Zero(t, d.fetchStalledFor(), "no previous cycle's stall")
	recv(t, probe.started, "the cycle")
	assert.Equal(t, sectionOtherFetch, d.section(), "held in the IMAP probe")
	assert.Zero(t, d.fetchStalledFor(), "the clock has not moved since startCycle")
	c.cancelFetch(errCycleRestart)
	recv(t, c.done, "the cycle's end")
}

// onSleep drops the pooled connections on every path and cancels only
// fetches still running.
func TestOnSleep_Paths(t *testing.T) {
	setWakeSettle(t, time.Hour)
	drops := countDrops(t)
	d := newQuietDaemon(t)

	t.Run("idle", func(t *testing.T) {
		var settle *time.Timer
		d.onSleep(nil, &settle, time.Minute)
		require.NotNil(t, settle, "an idle sleep starts the delay")
		settle.Stop()
	})
	t.Run("settling", func(t *testing.T) {
		settle := time.NewTimer(time.Hour)
		defer settle.Stop()
		d.onSleep(nil, &settle, time.Minute)
	})
	newCycle := func(s cycleSection) (*syncCycle, context.Context) {
		fetchCtx, cancel := context.WithCancelCause(context.Background())
		t.Cleanup(func() { cancel(nil) })
		d.setSection(s)
		return &syncCycle{cancelFetch: cancel}, fetchCtx
	}
	t.Run("fetching", func(t *testing.T) {
		c, fetchCtx := newCycle(sectionOtherFetch)
		var settle *time.Timer
		d.onSleep(c, &settle, time.Minute)
		assert.True(t, c.slept)
		assert.ErrorIs(t, context.Cause(fetchCtx), errCycleSlept)
		assert.Nil(t, settle, "the delay starts once the cycle returns")
	})
	t.Run("pipelines", func(t *testing.T) {
		c, fetchCtx := newCycle(sectionPipelines)
		var settle *time.Timer
		d.onSleep(c, &settle, time.Minute)
		assert.True(t, c.slept)
		// The pipelines run on the daemon's context; the cancel only skips
		// the history backfill after them.
		assert.ErrorIs(t, context.Cause(fetchCtx), errCycleSlept)
	})
	t.Run("backfill", func(t *testing.T) {
		c, fetchCtx := newCycle(sectionBackfill)
		var settle *time.Timer
		d.onSleep(c, &settle, time.Minute)
		assert.True(t, c.slept)
		assert.ErrorIs(t, context.Cause(fetchCtx), errCycleSlept)
	})
	assert.Equal(t, int32(5), drops.Load(), "every path drops the pooled connections")
}

// monoNow's default measures from an epoch that carries a monotonic
// reading: without one, time.Since would subtract wall clocks and a sleep
// would count as a fetch stall.
func TestMonoEpoch_HasMonotonicReading(t *testing.T) {
	assert.Contains(t, monoEpoch.String(), "m=")
}
