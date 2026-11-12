package cmd

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/daemon"
)

// writeTaggedPIDFile writes the current three-field, tagged pid-file
// format (daemon.PidFileFormatTag) — the shape a real WritePID produces on
// its normal (identity-read-succeeded) path, and the one identifyProcess
// checks with the tight symmetric pidReuseTolerance rather than the
// looser, one-sided legacy rule. Unlike writeFakePIDFile (legacy, which
// sidesteps identity checking via the 30-day mtime heuristic), a test using
// this must supply a matching identity via daemon.SetIdentityReaderForTest
// for a real helper subprocess to resolve as confirmed — a real subprocess
// here is never actually named "watchtower".
func writeTaggedPIDFile(t *testing.T, path string, pid int, startUnix int64) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	content := strconv.Itoa(pid) + " " + strconv.FormatInt(startUnix, 10) + " " + daemon.PidFileFormatTag
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
}

// TestRunSyncStop_RefusesWhenIdentityUnconfirmed pins the N2 requirement:
// runSyncStop's initial resolve, when a real helper's identity cannot be
// verified (daemon.ErrIdentityUnconfirmed via the real
// daemon.FindConfirmedProcess — not a cmd-level stub of verifyDaemonAlive),
// must refuse to signal it: return a clear error naming the pid, leave the
// pid file untouched, and never actually deliver a signal.
func TestRunSyncStop_RefusesWhenIdentityUnconfirmed(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)

	helper := startDelayedHelper(t)
	writeTaggedPIDFile(t, pidPath, helper.pid(), time.Now().Unix())
	rec := recordStop(t, helper)

	restore := daemon.SetIdentityReaderForTest(func(pid int) (daemon.ProcessIdentity, error) {
		return daemon.ProcessIdentity{}, errors.New("simulated identity read failure")
	})
	t.Cleanup(restore)

	err := runSyncStop(cfg, false)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "cannot confirm")
	assert.Contains(t, err.Error(), strconv.Itoa(helper.pid()))

	data, statErr := os.ReadFile(pidPath)
	require.NoError(t, statErr, "an unconfirmed identity must not remove the pid file")
	assert.Contains(t, string(data), strconv.Itoa(helper.pid()))

	assert.Empty(t, rec.sent(), "runSyncStop must refuse before ever sending a signal")
	// The delayed helper prints "signalled" on SIGTERM receipt, so a signal
	// sent around the seam may show too.
	_ = helper.cmd.Process.Kill()
	for line := range helper.events {
		assert.NotEqual(t, "signalled", line, "the helper was signalled")
	}
}

// TestRunSyncNow_RefusesWhenIdentityUnconfirmed pins the same requirement
// for runSyncNow. The swallow-forever helper is used deliberately: it never
// installs a SIGUSR1 handler, so the OS default action (terminate) would
// kill it outright if runSyncNow actually sent daemon.TriggerSignal despite
// the unconfirmed identity — a strong, unambiguous failure signal if the
// refusal is ever lost.
func TestRunSyncNow_RefusesWhenIdentityUnconfirmed(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)

	helper := startStuckHelper(t)
	writeTaggedPIDFile(t, pidPath, helper.pid(), time.Now().Unix())

	restore := daemon.SetIdentityReaderForTest(func(pid int) (daemon.ProcessIdentity, error) {
		return daemon.ProcessIdentity{}, errors.New("simulated identity read failure")
	})
	t.Cleanup(restore)

	err := runSyncNow(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "cannot confirm")

	data, statErr := os.ReadFile(pidPath)
	require.NoError(t, statErr, "an unconfirmed identity must not remove the pid file")
	assert.Contains(t, string(data), strconv.Itoa(helper.pid()))

	assert.NoError(t, syscall.Kill(helper.pid(), 0), "helper must not have been signalled (SIGUSR1's default action would have killed it)")
}

// TestForceStopSync_RefusesWhenIdentityUnconfirmed pins the same
// requirement for forceStopSync's verifyDaemonAlive re-check, going
// through the REAL production wiring (daemon.FindConfirmedProcess), not
// the cmd-level verifyDaemonAlive test seam the other forceStopSync tests
// use to simulate "gone/reused". The identity reader returns a genuinely
// matching identity on its first call (so runSyncStop's initial resolve
// succeeds and the first SIGTERM is sent, same as any other run) and fails
// from the second call on — reached only by forceStopSync's re-check
// before escalating further, exactly mirroring
// TestForceStopSync_ReVerifiesIdentityBeforeSIGKILLSpecifically's
// call-counting technique to prove escalation stopped at the FIRST
// re-check (no third read, which would precede SIGKILL).
func TestForceStopSync_RefusesWhenIdentityUnconfirmed(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)

	helper := startStuckHelper(t)
	rec := recordStop(t, helper)

	writeTime := time.Now()
	writeTaggedPIDFile(t, pidPath, helper.pid(), writeTime.Unix())

	var reads atomic.Int32
	restore := daemon.SetIdentityReaderForTest(func(pid int) (daemon.ProcessIdentity, error) {
		if reads.Add(1) == 1 {
			return daemon.ProcessIdentity{StartTime: writeTime, Comm: "watchtower"}, nil
		}
		return daemon.ProcessIdentity{}, errors.New("simulated identity read failure on re-check")
	})
	t.Cleanup(restore)

	var err error
	stdout := captureStdout(t, func() {
		err = runSyncStop(cfg, true)
	})
	require.NoError(t, err, "an unconfirmed identity must be a clean stop, not an error")
	assert.Contains(t, stdout, "can no longer be confirmed as still running")
	assert.Equal(t, int32(2), reads.Load(),
		"expected exactly two identity reads: the initial resolve, then forceStopSync's one re-check before the second SIGTERM — no third read, which would precede SIGKILL")

	assert.Equal(t, []sentSignal{{helper.pid(), syscall.SIGTERM}}, rec.sent(), "only the first SIGTERM, before the failed re-check")
	assert.NoError(t, syscall.Kill(helper.pid(), 0), "helper should still be running: it only ever swallows signals")
}

// TestRunSyncStop_TaggedFormatConfirmedSameSucceeds is the N2 "one cmd test
// going through the timestamped (new-format) path" requirement: a tagged
// pid file whose identity genuinely matches (supplied via
// daemon.SetIdentityReaderForTest, since a real subprocess here is never
// actually named "watchtower") flows through runSyncStop exactly like the
// legacy-format tests elsewhere in this package — signal delivered, helper
// exits, pid file removed.
func TestRunSyncStop_TaggedFormatConfirmedSameSucceeds(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)

	helper := startDelayedHelper(t)
	recordStop(t, helper)

	writeTime := time.Now()
	writeTaggedPIDFile(t, pidPath, helper.pid(), writeTime.Unix())

	restore := daemon.SetIdentityReaderForTest(func(pid int) (daemon.ProcessIdentity, error) {
		return daemon.ProcessIdentity{StartTime: writeTime, Comm: "watchtower"}, nil
	})
	t.Cleanup(restore)

	var err error
	stdout := captureStdout(t, func() {
		err = runSyncStop(cfg, false)
	})
	require.NoError(t, err)
	assert.Contains(t, stdout, "Daemon stopped.")

	_, statErr := os.Stat(pidPath)
	assert.True(t, os.IsNotExist(statErr), "pid file should be removed once the daemon is confirmed dead")

	<-helper.done
	assert.NoError(t, helper.err, "the delayed helper exits cleanly on its own")
}

// TestRunSyncNow_NoDaemonFails pins that `sync --now` without a running
// daemon fails with a hint instead of syncing in-process (the daemon's flock
// exists to keep a second syncer out).
func TestRunSyncNow_NoDaemonFails(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)
	_, statErr := os.Stat(pidPath)
	require.True(t, os.IsNotExist(statErr), "fixture must start without a pid file")

	err := runSyncNow(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no daemon is running")
}
