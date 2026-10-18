package daemon

import (
	"context"
	"log"
	"os"
	"os/signal"
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
	drainUntilClosed(t, ch)
}

// After ctx is done the watcher leaves the signal ignored instead of
// handing it back to its default disposition: a CLI that read the
// capabilities file just before the daemon removed it gets an explicit no-op
// from a shutting-down daemon. signal.Ignored pins the
// disposition (signal.Stop would leave it false); the self-signal below must
// not end the test process either.
func TestWatchAutomationWake_ShutdownKeepsSignalIgnored(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := WatchAutomationWake(ctx)
	require.False(t, signal.Ignored(AutomationWakeSignal), "handled while watching")
	cancel()
	drainUntilClosed(t, ch)

	assert.True(t, signal.Ignored(AutomationWakeSignal), "the wake signal must stay ignored after shutdown")
	require.NoError(t, syscall.Kill(os.Getpid(), AutomationWakeSignal))
	time.Sleep(200 * time.Millisecond)
}

func drainUntilClosed(t *testing.T, ch <-chan struct{}) {
	t.Helper()
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
// with a long poll interval (only the initial sync fires), fake runners and an
// injected wake channel.
func newAutomationTestDaemon(t *testing.T, syncCount *atomic.Int32) (*Daemon, *fakeAutomationRunner, *fakeAutomationRunner, chan struct{}) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	orch, _ := newTestOrchestrator(t, syncCount)
	cfg := &config.Config{Sync: config.SyncConfig{PollInterval: 10 * time.Second}}
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
	d, sched, exec, wakeCh := newAutomationTestDaemon(t, &syncCount)

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

// Never wired (no SetAutomations — the upgrade step failed closed): Run must
// neither panic nor start anything.
func TestDaemon_AutomationsUnwiredStartsNothing(t *testing.T) {
	var syncCount atomic.Int32
	t.Setenv("HOME", t.TempDir())
	orch, _ := newTestOrchestrator(t, &syncCount)
	d := newDaemon(orch, &config.Config{Sync: config.SyncConfig{PollInterval: 10 * time.Second}})
	d.SetLogger(log.New(os.Stderr, "[test-daemon] ", 0))
	wakeCh := make(chan struct{}, 1)
	d.automationWakeCh = wakeCh
	wakeCh <- struct{}{}
	require.NoError(t, runDaemonUntil(t, d, func() bool { return syncCount.Load() >= 1 }))
}

// A running daemon advertises its automations wake beside its PID file, under
// its own pid, and removes the advertisement when it stops — the CLI signals
// only a daemon that advertises it (an older one ignores SIGUSR2, so the run
// would just wait for its next poll).
func TestDaemon_AdvertisesAutomationWakeCapability(t *testing.T) {
	var syncCount atomic.Int32
	d, _, _, _ := newAutomationTestDaemon(t, &syncCount)
	pidPath := t.TempDir() + "/daemon.pid"
	d.SetPIDPath(pidPath)

	var advertised bool
	err := runDaemonUntil(t, d, func() bool {
		ok, err := HasCapability(pidPath, os.Getpid(), AutomationWakeCapability)
		require.NoError(t, err)
		advertised = ok
		return ok
	})
	require.NoError(t, err)
	assert.True(t, advertised)
	assert.NoFileExists(t, CapsPath(pidPath), "removed with the PID file")
}

// With the scheduler/executor never wired (the upgrade step failed closed),
// the daemon starts neither and advertises no wake: the CLI then says it
// could not wake it instead of signalling a daemon that would drop the wake.
func TestDaemon_InactiveAutomationsAdvertiseNoWake(t *testing.T) {
	var syncCount atomic.Int32
	d, _, _, _ := newAutomationTestDaemon(t, &syncCount)
	d.SetAutomations(nil, nil)
	pidPath := t.TempDir() + "/daemon.pid"
	d.SetPIDPath(pidPath)
	err := runDaemonUntil(t, d, func() bool {
		if syncCount.Load() < 1 {
			return false
		}
		assert.FileExists(t, pidPath, "the daemon is running")
		assert.NoFileExists(t, CapsPath(pidPath), "no wake advertised")
		return true
	})
	require.NoError(t, err)
}

func TestHasCapability_StaleOrMissingFileAdvertisesNothing(t *testing.T) {
	pidPath := t.TempDir() + "/daemon.pid"
	ok, err := HasCapability(pidPath, 42, AutomationWakeCapability)
	require.NoError(t, err)
	assert.False(t, ok, "no file")

	require.NoError(t, os.WriteFile(CapsPath(pidPath), []byte("41\nautomations-wake\n"), 0o600))
	ok, err = HasCapability(pidPath, 42, AutomationWakeCapability)
	require.NoError(t, err)
	assert.False(t, ok, "a file an earlier daemon left names another pid")

	require.NoError(t, os.WriteFile(CapsPath(pidPath), []byte("42\nsomething-else\n"), 0o600))
	ok, err = HasCapability(pidPath, 42, AutomationWakeCapability)
	require.NoError(t, err)
	assert.False(t, ok, "capability not listed")

	require.NoError(t, os.WriteFile(CapsPath(pidPath), []byte("42\nautomations-wake\n"), 0o600))
	ok, err = HasCapability(pidPath, 42, AutomationWakeCapability)
	require.NoError(t, err)
	assert.True(t, ok)
}
