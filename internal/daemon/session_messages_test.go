package daemon

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeDeliverer is a MessageDeliverer over fakeAutomationRunner's records.
type fakeDeliverer struct{ *fakeAutomationRunner }

func (f fakeDeliverer) Start(ctx context.Context) error { return f.Run(ctx) }

// DaemonRunning only reads the pid file: it never creates, opens or locks
// sync.lock, so a test that holds the lock still reads "not running", and a
// live confirmed pid reads "running" whoever holds the lock.
func TestDaemonRunningNeverTakesSyncLock(t *testing.T) {
	ws := t.TempDir()
	running, err := DaemonRunning(ws)
	require.NoError(t, err)
	assert.False(t, running, "no pid file")
	assert.NoFileExists(t, filepath.Join(ws, "sync.lock"), "the probe never creates the lock")

	lock, err := os.OpenFile(filepath.Join(ws, "sync.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	require.NoError(t, err)
	t.Cleanup(func() { _ = lock.Close() })
	require.NoError(t, syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))

	running, err = DaemonRunning(ws)
	require.NoError(t, err)
	assert.False(t, running, "a held sync lock is not a daemon (a one-shot sync holds it too)")

	start := ownStartTime(t)
	writeTaggedPID(t, filepath.Join(ws, "daemon.pid"), os.Getpid(), start.Unix())
	stubProcessIdentity(t, func(int) (processIdentity, error) {
		return processIdentity{startTime: start, comm: "watchtower"}, nil
	})
	running, err = DaemonRunning(ws)
	require.NoError(t, err)
	assert.True(t, running, "a live confirmed daemon pid")

	// The test's lock is still the only one: a second descriptor cannot take it.
	other, err := os.OpenFile(filepath.Join(ws, "sync.lock"), os.O_RDWR, 0o600)
	require.NoError(t, err)
	defer other.Close()
	assert.Error(t, syscall.Flock(int(other.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))

	writeTaggedPID(t, filepath.Join(ws, "daemon.pid"), exitedChildPID(t), start.Unix())
	running, err = DaemonRunning(ws)
	require.NoError(t, err)
	assert.False(t, running, "a pid file left by a daemon that exited")
}

// The deliverer runs beside the sync loop, is reaped before Run returns, and
// gets the wake signal with automations unwired and wired alike; the daemon
// advertises the messages wake while it runs.
func TestDaemon_SessionMessagesStartAndWake(t *testing.T) {
	for _, automations := range []bool{false, true} {
		t.Run(map[bool]string{false: "automations unwired", true: "automations wired"}[automations], func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var syncCount atomic.Int32
				d, sched, exec, wakeCh := newAutomationTestDaemon(t, &syncCount)
				if !automations {
					d.SetAutomations(nil, nil)
				}
				msgs := fakeDeliverer{newFakeAutomationRunner()}
				d.SetMessageDeliverer(msgs)
				pidPath := t.TempDir() + "/daemon.pid"
				d.SetPIDPath(pidPath)

				sent, advertised := false, false
				err := runDaemonUntil(t, d, func() bool {
					if !sent && syncCount.Load() >= 1 && msgs.started.Load() {
						ok, err := HasCapability(pidPath, os.Getpid(), SessionMessagesWakeCapability)
						require.NoError(t, err)
						advertised = ok
						wakeCh <- struct{}{}
						sent = true
					}
					return msgs.wakes.Load() == 1
				}, msgs.poke)
				require.NoError(t, err)

				assert.True(t, advertised, "the messages wake is advertised")
				assert.Equal(t, int32(1), syncCount.Load(), "a wake runs no sync")
				assert.True(t, msgs.stopped.Load(), "the deliverer was reaped before Run returned")
				if automations {
					assert.Equal(t, int32(1), sched.wakes.Load())
					assert.Equal(t, int32(1), exec.wakes.Load())
				}
				assert.NoFileExists(t, CapsPath(pidPath))
			})
		})
	}
}
