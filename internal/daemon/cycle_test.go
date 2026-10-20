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
// request hung on a socket a sleep killed.
type cycleProbe struct {
	started   chan time.Time // one send per Sync
	cancelled chan struct{}  // one send per blocked Sync whose ctx was cancelled
	block     atomic.Bool
}

func newCycleProbe() *cycleProbe {
	return &cycleProbe{started: make(chan time.Time, 16), cancelled: make(chan struct{}, 16)}
}

func (p *cycleProbe) Sync(ctx context.Context) (int, error) {
	p.started <- time.Now()
	if !p.block.Load() {
		return 0, nil
	}
	<-ctx.Done()
	p.cancelled <- struct{}{}
	return 0, ctx.Err()
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

// shortenWakeSettle keeps a wake-driven test from waiting the real delay.
func shortenWakeSettle(t *testing.T) {
	t.Helper()
	setWakeSettle(t, 10*time.Millisecond)
}

// loopHarness is a running daemon loop with a probe in its source-sync
// section and an injected wake channel.
type loopHarness struct {
	probe  *cycleProbe
	wake   chan time.Duration
	logs   *lockedLog
	cancel context.CancelFunc
	done   chan error
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
	d.triggerCh = make(chan struct{})

	ctx, cancel := context.WithCancel(context.Background())
	h := &loopHarness{probe: probe, wake: wake, logs: logs, cancel: cancel, done: make(chan error, 1)}
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
