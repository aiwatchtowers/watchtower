package daemon

import (
	"bytes"
	"context"
	"log"
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

// cycleProbe is an IMAP syncer that reports each cycle reaching it and, while
// block is set, holds the cycle there until its context is cancelled — a
// request hung on a socket a sleep killed — or release lets it go.
type cycleProbe struct {
	started   chan time.Time // one send per Sync
	cancelled chan struct{}  // one send per blocked Sync whose ctx was cancelled
	release   chan struct{}  // a send ends one blocked Sync normally
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

func startLoop(t *testing.T, syncOnWake bool, wake chan time.Duration, blockFirst bool) *loopHarness {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{Sync: config.SyncConfig{PollInterval: time.Hour, SyncOnWake: syncOnWake}}
	d := newDaemon(nil, cfg)
	logs := &lockedLog{}
	d.SetLogger(log.New(logs, "", 0))
	probe := newCycleProbe()
	probe.block.Store(blockFirst)
	d.imapSyncers = []mailSyncer{probe}
	d.wakeCh = wake
	trigger := make(chan struct{})
	d.triggerCh = trigger
	wall := &fakeWall{base: time.Now().Round(0)}
	d.loopNow = wall.now

	ctx, cancel := context.WithCancel(context.Background())
	h := &loopHarness{d: d, probe: probe, wake: wake, trigger: trigger, wall: wall, logs: logs, cancel: cancel, done: make(chan error, 1)}
	go func() { h.done <- d.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
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

// A sleep detected while a cycle hangs in its source syncs cancels that cycle,
// which skips its pipelines, and a fresh cycle starts once the settle delay
// has passed.
func TestRunLoop_SleepCancelsRunningCycleAndStartsAFreshOne(t *testing.T) {
	const settle = 50 * time.Millisecond
	setWakeSettle(t, settle)
	h := startLoop(t, true, make(chan time.Duration, 1), true)

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wake <- 20 * time.Minute
	recv(t, h.probe.cancelled, "the running cycle's cancellation")
	cancelledAt := time.Now()

	restartedAt := recv(t, h.probe.started, "a fresh cycle after the wake")
	assert.GreaterOrEqual(t, restartedAt.Sub(cancelledAt), settle, "the fresh cycle waits out the settle delay")
	h.stop(t)

	assert.Equal(t, 1, h.logs.count("sleep detected (slept ~20m0s), cancelling the running cycle"))
	assert.Equal(t, 1, h.logs.count("skipping pipelines"), "only the cancelled cycle skips its pipelines")
}

// The cancel does not depend on sync.sync_on_wake; only the fresh cycle does:
// with it off, the next tick runs the cycle, not the wake.
func TestRunLoop_SleepCancelsCycleWithSyncOnWakeOff(t *testing.T) {
	shortenWakeSettle(t)
	h := startLoop(t, false, make(chan time.Duration, 1), true)

	recv(t, h.probe.started, "the initial cycle")
	h.wake <- 5 * time.Minute
	recv(t, h.probe.cancelled, "the running cycle's cancellation")
	requireNone(t, h.probe.started, 300*time.Millisecond, "cycle after a wake with sync_on_wake off")
	h.stop(t)
}

// A wake while idle with sync_on_wake on starts a cycle after the settle
// delay; another wake inside that delay starts the delay over.
func TestRunLoop_SleepDuringSettleRestartsTheDelay(t *testing.T) {
	const settle = 400 * time.Millisecond
	setWakeSettle(t, settle)
	// Unbuffered: a send returns only once the loop has taken the wake.
	h := startLoop(t, true, make(chan time.Duration), false)

	recv(t, h.probe.started, "the initial cycle")
	h.wake <- 10 * time.Minute // may wait for the initial cycle to finish
	time.Sleep(settle / 4)
	h.wake <- 10 * time.Minute
	secondWake := time.Now()

	restartedAt := recv(t, h.probe.started, "the cycle after the wakes")
	assert.GreaterOrEqual(t, restartedAt.Sub(secondWake), settle, "the second wake restarts the settle delay")
	assert.Equal(t, 1, h.logs.count("post-wake wait over"))
	h.stop(t)
}

// Shutdown mid-cycle: Run waits for the cycle to stop and starts no other.
func TestRunLoop_ShutdownDuringCycleStartsNoNewOne(t *testing.T) {
	shortenWakeSettle(t)
	h := startLoop(t, true, make(chan time.Duration, 1), true)

	recv(t, h.probe.started, "the initial cycle")
	h.stop(t)
	recv(t, h.probe.cancelled, "the cycle's cancellation")
	requireNone(t, h.probe.started, 100*time.Millisecond, "cycle after shutdown")
}

// Shutdown inside the settle delay returns at once and starts no cycle.
func TestRunLoop_ShutdownDuringSettleStartsNoCycle(t *testing.T) {
	setWakeSettle(t, time.Hour)
	h := startLoop(t, true, make(chan time.Duration), false)

	recv(t, h.probe.started, "the initial cycle")
	h.wake <- 10 * time.Minute
	h.stop(t)
	requireNone(t, h.probe.started, 100*time.Millisecond, "cycle after shutdown")
}

// pressSyncNow sends a manual trigger and returns once the loop has handled
// it: a second send on the unbuffered channel is taken only after the loop
// is back in its select (the second trigger collapses into the first).
func (h *loopHarness) pressSyncNow() {
	h.trigger <- struct{}{}
	h.trigger <- struct{}{}
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

// Sync Now while a cycle has been stuck in its source syncs for
// manualRestartAfter cancels it and starts a fresh cycle at once — no
// post-wake delay.
func TestRunLoop_TriggerLateInSourceSyncsRestartsTheCycle(t *testing.T) {
	setWakeSettle(t, time.Hour)
	drops := countDrops(t)
	h := startLoop(t, true, make(chan time.Duration, 1), true)

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wall.advance(manualRestartAfter)
	h.trigger <- struct{}{}
	recv(t, h.probe.cancelled, "the stuck cycle's cancellation")
	recv(t, h.probe.started, "the fresh cycle")
	h.stop(t)

	assert.Equal(t, int32(1), drops.Load(), "the pooled connections are dropped before the fresh cycle")
	assert.Equal(t, 1, h.logs.count("manual sync trigger received 1m0s into the cycle's source syncs, cancelling it and syncing afresh"))
}

// Sync Now within manualRestartAfter of the cycle's start is queued: the
// cycle finishes and one more runs right after it.
func TestRunLoop_TriggerEarlyInSourceSyncsWaitsForTheCycle(t *testing.T) {
	drops := countDrops(t)
	h := startLoop(t, true, make(chan time.Duration, 1), true)

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.wall.advance(manualRestartAfter - time.Second)
	h.pressSyncNow()
	assert.Equal(t, 0, h.logs.count("afresh"), "a young cycle is not cancelled")
	assert.Equal(t, 2, h.logs.count("during the cycle's source syncs, syncing after it"))

	h.releaseProbe(t)
	recv(t, h.probe.started, "the queued cycle")
	h.stop(t)
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
	assert.Zero(t, drops.Load(), "a queued trigger leaves the connections alone")
}

// Sync Now while the cycle runs its pipelines is queued whatever its age: the
// sources are already fetched.
func TestRunLoop_TriggerDuringPipelinesWaitsForTheCycle(t *testing.T) {
	h := startLoop(t, true, make(chan time.Duration, 1), true)

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.d.cycleInPipelines.Store(true) // as runSync marks it past the source syncs
	h.wall.advance(10 * manualRestartAfter)
	h.pressSyncNow()
	assert.Equal(t, 0, h.logs.count("afresh"), "a cycle in its pipelines is not cancelled")
	assert.Equal(t, 2, h.logs.count("during the cycle's pipelines, syncing after it"))

	h.releaseProbe(t)
	recv(t, h.probe.started, "the queued cycle")
	h.stop(t)
	assert.Empty(t, h.probe.cancelled, "no cycle was cancelled before shutdown")
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

	d.runSync(context.Background())
	assert.False(t, duringSync.Load(), "the source syncs run outside the pipelines section")
	assert.True(t, d.cycleInPipelines.Load(), "the pipelines section is marked")
}
