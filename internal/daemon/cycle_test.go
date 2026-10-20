package daemon

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"strconv"
	"strings"
	gosync "sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/config"

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
}

func newCycleProbe() *cycleProbe {
	return &cycleProbe{started: make(chan time.Time, 16), cancelled: make(chan struct{}, 16), release: make(chan struct{})}
}

func (p *cycleProbe) Sync(ctx context.Context) (int, error) {
	if p.onSync != nil {
		p.onSync()
	}
	p.started <- time.Now()
	if !p.block.Load() {
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

func (p *cycleProbe) FetchRange(context.Context, time.Time, time.Time) (int, error) { return 0, nil }
func (p *cycleProbe) AccountID() int64                                              { return 1 }
func (p *cycleProbe) FirstSyncFrom() (time.Time, bool)                              { return time.Time{}, false }

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

// fakeWall is runLoop's wall clock in a test, moved by hand.
type fakeWall struct {
	base   time.Time
	offset atomic.Int64
}

func (w *fakeWall) now() time.Time           { return w.base.Add(time.Duration(w.offset.Load())) }
func (w *fakeWall) advance(by time.Duration) { w.offset.Add(int64(by)) }

// loopHarness is a running daemon loop with a probe in its source-sync
// section, injected wake and trigger channels and a fake wall clock.
type loopHarness struct {
	d       *Daemon
	probe   *cycleProbe
	wake    chan time.Duration
	trigger chan struct{} // unbuffered: a send returns once the loop took it
	wall    *fakeWall
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
	probe := newCycleProbe()
	probe.block.Store(o.blockFirst)
	if o.hold {
		probe.hold = make(chan struct{})
	}
	d.imapSyncers = []mailSyncer{probe}
	d.wakeCh = o.wake
	trigger := make(chan struct{})
	d.triggerCh = trigger
	wall := &fakeWall{base: time.Now().Round(0)}
	d.loopNow = wall.now

	ctx, cancel := context.WithCancel(context.Background())
	h := &loopHarness{d: d, probe: probe, wake: o.wake, trigger: trigger, wall: wall, logs: logs, cancel: cancel, done: make(chan error, 1)}
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
	logRestarts       = "without source-sync progress, cancelling them and syncing afresh"
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

// A sleep detected while the cycle runs its pipelines cancels nothing: the
// cycle finishes them, and a fresh one follows the settle delay.
func TestRunLoop_SleepDuringPipelinesLetsThemFinish(t *testing.T) {
	shortenWakeSettle(t)
	drops := countDrops(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.d.cycleInPipelines.Store(true) // as runSync marks it past the source syncs
	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, "during the cycle's pipelines, letting them finish", 1)
	assert.Equal(t, int32(1), drops.Load(), "the idle connections are dropped at once")
	assert.Empty(t, h.probe.cancelled, "the cycle is not cancelled")

	h.releaseProbe(t)
	recv(t, h.probe.started, "the cycle after the wake")
	h.stop(t)
	assert.Zero(t, h.logs.count("skipping pipelines"), "the cycle ran its pipelines")
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
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

// Sync Now while a cycle's source syncs have made no progress for
// manualRestartAfter cancels them and starts a fresh cycle at once — no
// post-wake delay.
func TestRunLoop_TriggerOnStalledSourceSyncsRestartsTheCycle(t *testing.T) {
	setWakeSettle(t, time.Hour)
	drops := countDrops(t)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wall.advance(manualRestartAfter)
	h.trigger <- struct{}{}
	recv(t, h.probe.cancelled, "the stalled cycle's cancellation")
	recv(t, h.probe.started, "the fresh cycle")
	h.stop(t)

	assert.Equal(t, int32(1), drops.Load(), "the pooled connections are dropped before the fresh cycle")
	assert.Equal(t, 1, h.logs.count("manual sync trigger received after 1m0s "+logRestarts))
	assert.Equal(t, 1, h.logs.count("source syncs stopped by Sync Now restart, skipping pipelines"))
}

// Sync Now on an old cycle whose source syncs still make progress (a long
// first sync, a slow Jira pass) is queued: the cycle finishes and one more
// runs right after it.
func TestRunLoop_TriggerOnMovingSourceSyncsWaitsForTheCycle(t *testing.T) {
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wall.advance(10 * manualRestartAfter)
	h.d.markFetchProgress() // as the Slack heartbeat does when its counters move
	h.wall.advance(manualRestartAfter - time.Second)
	h.pressSyncNow(t, logQueuedFetching)
	assert.Zero(t, h.logs.count("afresh"), "a cycle still making progress is not cancelled")

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
	h.wall.advance(manualRestartAfter - time.Second)
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

// Sync Now while the cycle runs its pipelines is queued whatever its stall:
// the sources are already fetched.
func TestRunLoop_TriggerDuringPipelinesWaitsForTheCycle(t *testing.T) {
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.d.cycleInPipelines.Store(true) // as runSync marks it past the source syncs
	h.wall.advance(10 * manualRestartAfter)
	h.pressSyncNow(t, "during the cycle's pipelines, syncing after it")
	assert.Zero(t, h.logs.count("afresh"), "a cycle in its pipelines is not cancelled")

	h.releaseProbe(t)
	recv(t, h.probe.started, "the queued cycle")
	h.stop(t)
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
}

// A sleep that lands after Sync Now restarted the cycle, before it returned,
// does not lose the restart: the fresh cycle runs after the settle delay even
// with sync_on_wake off.
func TestRunLoop_RestartThenSleepStillSyncsAfterTheDelay(t *testing.T) {
	shortenWakeSettle(t)
	h := startLoop(t, loopOpts{blockFirst: true, hold: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wall.advance(manualRestartAfter)
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

// runSync clears the pipelines marker for its source syncs and sets it before
// the pipelines.
func TestRunSync_MarksThePipelinesSection(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newDaemon(nil, &config.Config{})
	d.SetLogger(log.New(&lockedLog{}, "", 0))
	d.cycleInPipelines.Store(true) // left over from the previous cycle
	probe := newCycleProbe()
	var duringSync atomic.Bool
	probe.onSync = func() { duringSync.Store(d.cycleInPipelines.Load()) }
	d.imapSyncers = []mailSyncer{probe}

	d.runSync(context.Background(), context.Background())
	assert.False(t, duringSync.Load(), "the source syncs run outside the pipelines section")
	assert.True(t, d.cycleInPipelines.Load(), "the pipelines section is marked")
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

// startCycle resets the pipelines marker and the progress stamp on the loop
// goroutine, before the cycle's goroutine runs: a trigger right after it
// never reads the previous cycle's state.
func TestStartCycle_ResetsTheCycleStateFirst(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newDaemon(nil, &config.Config{})
	d.SetLogger(log.New(&lockedLog{}, "", 0))
	wall := &fakeWall{base: time.Now().Round(0)}
	d.loopNow = wall.now
	probe := newCycleProbe()
	probe.block.Store(true)
	d.imapSyncers = []mailSyncer{probe}
	d.cycleInPipelines.Store(true)
	d.markFetchProgress()
	wall.advance(time.Hour)

	c := d.startCycle(context.Background(), true)
	assert.False(t, d.cycleInPipelines.Load())
	assert.Zero(t, d.fetchStalledFor())
	recv(t, probe.started, "the cycle")
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
	newCycle := func(inPipelines bool) (*syncCycle, context.Context) {
		fetchCtx, cancel := context.WithCancelCause(context.Background())
		t.Cleanup(func() { cancel(nil) })
		d.cycleInPipelines.Store(inPipelines)
		return &syncCycle{cancelFetch: cancel}, fetchCtx
	}
	t.Run("fetching", func(t *testing.T) {
		c, fetchCtx := newCycle(false)
		var settle *time.Timer
		d.onSleep(c, &settle, time.Minute)
		assert.True(t, c.slept)
		assert.ErrorIs(t, context.Cause(fetchCtx), errCycleSlept)
		assert.Nil(t, settle, "the delay starts once the cycle returns")
	})
	t.Run("pipelines", func(t *testing.T) {
		c, fetchCtx := newCycle(true)
		var settle *time.Timer
		d.onSleep(c, &settle, time.Minute)
		assert.True(t, c.slept)
		assert.NoError(t, fetchCtx.Err(), "pipelines are never cancelled")
	})
	assert.Equal(t, int32(4), drops.Load(), "every path drops the pooled connections")
}

// wallNow's default is the wall clock with no monotonic reading: the
// fetch-progress stall it measures must count the time a sleep took.
func TestWallNow_DefaultHasNoMonotonicReading(t *testing.T) {
	d := newQuietDaemon(t)
	assert.NotContains(t, d.wallNow().String(), "m=")
}
