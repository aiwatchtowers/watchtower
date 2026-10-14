package daemon

import (
	"context"
	"log"
	"os"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

// fakeAutomationRunner records what the daemon does with an AutomationRunner:
// whether Run started, how many Wakes it got, and whether Run returned.
type fakeAutomationRunner struct {
	started atomic.Bool
	stopped atomic.Bool
	wakes   atomic.Int32
}

func (f *fakeAutomationRunner) Run(ctx context.Context) error {
	f.started.Store(true)
	<-ctx.Done()
	// A real executor finishes its in-flight runs after ctx ends; the daemon
	// must wait for that before Run returns.
	time.Sleep(50 * time.Millisecond)
	f.stopped.Store(true)
	return nil
}

func (f *fakeAutomationRunner) Wake() { f.wakes.Add(1) }

func TestWatchAutomationWake_CoalescesAndCloses(t *testing.T) {
	require.NotEqual(t, TriggerSignal, AutomationWakeSignal, "SIGUSR1 keeps meaning sync")
	require.Equal(t, syscall.SIGUSR2, AutomationWakeSignal)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := WatchAutomationWake(ctx)

	for range 5 {
		require.NoError(t, syscall.Kill(os.Getpid(), AutomationWakeSignal))
	}
	receiveWithin(t, ch, "wake signal did not reach the channel")

	// The forwarder still serves after a burst.
	require.NoError(t, syscall.Kill(os.Getpid(), AutomationWakeSignal))
	receiveWithin(t, ch, "forwarder stopped serving after a burst")

	cancel()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("wake channel was not closed after context cancellation")
		}
	}
}

func receiveWithin(t *testing.T, ch <-chan struct{}, msg string) {
	t.Helper()
	select {
	case _, ok := <-ch:
		require.True(t, ok, "channel should deliver a wake, not a close")
	case <-time.After(2 * time.Second):
		t.Fatal(msg)
	}
}

// newAutomationTestDaemon is a daemon over the counting test orchestrator
// with a long poll interval (only the initial sync fires), automations
// enabled or not, fake runners and an injected wake channel.
func newAutomationTestDaemon(t *testing.T, enabled bool, syncCount *atomic.Int32) (*Daemon, *fakeAutomationRunner, *fakeAutomationRunner, chan struct{}) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	orch, _ := newTestOrchestrator(t, syncCount)
	cfg := &config.Config{
		Sync:        config.SyncConfig{PollInterval: 10 * time.Second},
		Automations: config.AutomationsConfig{Enabled: enabled},
	}
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-daemon] ", 0))
	sched, exec := &fakeAutomationRunner{}, &fakeAutomationRunner{}
	d.SetAutomations(sched, exec)
	wakeCh := make(chan struct{}, 1)
	d.automationWakeCh = wakeCh
	return d, sched, exec, wakeCh
}

func TestDaemon_AutomationWakeSignalDoesNotStartSync(t *testing.T) {
	var syncCount atomic.Int32
	d, sched, exec, wakeCh := newAutomationTestDaemon(t, true, &syncCount)

	sent := false
	err := runDaemonUntil(t, d, func() bool {
		if !sent && syncCount.Load() >= 1 && sched.started.Load() && exec.started.Load() {
			wakeCh <- struct{}{}
			sent = true
		}
		return sched.wakes.Load() == 1 && exec.wakes.Load() == 1
	})
	require.NoError(t, err)

	assert.Equal(t, int32(1), syncCount.Load(), "a wake runs no sync: only the initial one")
	assert.Equal(t, int32(1), sched.wakes.Load())
	assert.Equal(t, int32(1), exec.wakes.Load())
	// Run returned only after both goroutines ended (no orphans).
	assert.True(t, sched.stopped.Load(), "scheduler goroutine was not reaped before Run returned")
	assert.True(t, exec.stopped.Load(), "executor goroutine was not reaped before Run returned")
}

func TestDaemon_AutomationsDisabledStartsNothing(t *testing.T) {
	var syncCount atomic.Int32
	d, sched, exec, wakeCh := newAutomationTestDaemon(t, false, &syncCount)

	var sentAt time.Time
	err := runDaemonUntil(t, d, func() bool {
		if sentAt.IsZero() && syncCount.Load() >= 1 {
			wakeCh <- struct{}{}
			sentAt = time.Now()
		}
		// Give a (wrongly) started runner time to see the wake.
		return !sentAt.IsZero() && time.Since(sentAt) > 200*time.Millisecond
	})
	require.NoError(t, err)

	assert.False(t, sched.started.Load(), "scheduler started with automations disabled")
	assert.False(t, exec.started.Load(), "executor started with automations disabled")
	assert.Zero(t, sched.wakes.Load())
	assert.Zero(t, exec.wakes.Load())
	assert.Equal(t, int32(1), syncCount.Load(), "a wake runs no sync")
}

// Enabled but never wired (no SetAutomations): Run must neither panic nor
// start anything.
func TestDaemon_AutomationsUnwiredStartsNothing(t *testing.T) {
	var syncCount atomic.Int32
	t.Setenv("HOME", t.TempDir())
	orch, _ := newTestOrchestrator(t, &syncCount)
	d := newDaemon(orch, &config.Config{
		Sync:        config.SyncConfig{PollInterval: 10 * time.Second},
		Automations: config.AutomationsConfig{Enabled: true},
	})
	d.SetLogger(log.New(os.Stderr, "[test-daemon] ", 0))
	wakeCh := make(chan struct{}, 1)
	d.automationWakeCh = wakeCh
	wakeCh <- struct{}{}
	require.NoError(t, runDaemonUntil(t, d, func() bool { return syncCount.Load() >= 1 }))
}
