package cmd

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

// TestSyncStop_HelperProcess is not a real test: it is re-executed as a
// subprocess (the GO_WANT_HELPER_PROCESS re-exec pattern used by
// cmd/shutdown_test.go) so TestRunSyncStop_TimeoutReportsForceHint and
// TestRunSyncStop_ForceKillsStuckDaemon can point runSyncStop at a real PID
// that behaves like the stuck daemon in the shutdown-hang RCA: it installs
// its own SIGTERM handler that swallows the signal entirely (no
// notifyShutdownContext, the worst case) rather than exiting, so only
// SIGKILL — which cannot be caught or ignored — ever ends it. Run the
// ordinary way (no env var set) it is a silent no-op.
func TestSyncStop_HelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}

	sigCh := make(chan os.Signal, 8)
	signal.Notify(sigCh, syscall.SIGTERM)
	go func() {
		for range sigCh {
			// Swallow every SIGTERM — never exit on it.
		}
	}()

	fmt.Println("ready")
	select {}
}

// startSyncStopHelper re-execs the test binary into the helper process
// above and returns it together with a channel of its scanned stdout
// lines, mirroring cmd/shutdown_test.go's startShutdownHelper.
func startSyncStopHelper(t *testing.T) (*exec.Cmd, <-chan string) {
	t.Helper()

	helper := exec.Command(os.Args[0], "-test.run=^TestSyncStop_HelperProcess$")
	helper.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
	helper.Stderr = os.Stderr

	stdout, err := helper.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	if err := helper.Start(); err != nil {
		t.Fatalf("starting helper process: %v", err)
	}

	lines := make(chan string, 16)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
	}()

	return helper, lines
}

func waitForSyncStopHelperReady(t *testing.T, lines <-chan string) {
	t.Helper()
	select {
	case line, ok := <-lines:
		if !ok || line != "ready" {
			t.Fatalf("helper process did not report ready (got %q, ok=%v)", line, ok)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for helper process to report ready")
	}
}

// syncStopTestConfig points a *config.Config at a fresh temp workspace and
// returns it plus the pid-file path runSyncStop will read/write.
func syncStopTestConfig(t *testing.T) (*config.Config, string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws"}
	return cfg, pidFilePath(cfg)
}

// writeFakePIDFile writes pid in the legacy (no-timestamp) pid-file format,
// so daemon.FindProcess's PID-reuse check (which, once a timestamp is
// present, compares the process's actual OS start time against the stored
// one) never engages at all — these tests care about signal/grace-period
// behavior, not PID-reuse detection, which internal/daemon's own pidfile
// tests cover directly.
func writeFakePIDFile(t *testing.T, path string, pid int) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(strconv.Itoa(pid)), 0o600))
}

// writeFakePIDFileWithTimestamp writes pid in the current "PID TIMESTAMP"
// format, timestamped to the moment of the call. A pid whose process really
// started only moments ago (any helper this file spawns) is always within
// isReusedPID's tolerance of "now", so this reliably resolves as a live,
// correctly-identified — not reused — process, without needing this
// package to reach into internal/daemon's own real-start-time lookup.
func writeFakePIDFileWithTimestamp(t *testing.T, path string, pid int) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	content := fmt.Sprintf("%d %d", pid, time.Now().Unix())
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
}

// TestSyncStop_DelayedHelperProcess is another helper subprocess (same
// re-exec pattern as TestSyncStop_HelperProcess) that exits shortly after
// receiving SIGTERM instead of instantly (a plain `sleep`) or never (the
// "stuck daemon" helper above) — giving a test a deterministic window in
// which the process is still alive-but-dying, to mutate state during. Run
// the ordinary way (no env var set) it is a silent no-op.
func TestSyncStop_DelayedHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS_DELAYED") != "1" {
		return
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM)

	fmt.Println("ready")
	<-sigCh
	time.Sleep(300 * time.Millisecond)
	os.Exit(0)
}

// startSyncStopDelayedHelper mirrors startSyncStopHelper but re-execs into
// TestSyncStop_DelayedHelperProcess.
func startSyncStopDelayedHelper(t *testing.T) (*exec.Cmd, <-chan string) {
	t.Helper()

	helper := exec.Command(os.Args[0], "-test.run=^TestSyncStop_DelayedHelperProcess$")
	helper.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS_DELAYED=1")
	helper.Stderr = os.Stderr

	stdout, err := helper.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	if err := helper.Start(); err != nil {
		t.Fatalf("starting helper process: %v", err)
	}

	lines := make(chan string, 16)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
	}()

	return helper, lines
}

// drainAndReap consumes lines to completion (required before Cmd.Wait, which
// os/exec forbids calling concurrently with an active StdoutPipe reader) and
// returns cmd's exit error over the returned channel.
func drainAndReap(cmd *exec.Cmd, lines <-chan string) <-chan error {
	done := make(chan error, 1)
	go func() {
		for range lines {
		}
		done <- cmd.Wait()
	}()
	return done
}

func setSyncStopGraces(t *testing.T, grace, forceGrace, poll time.Duration) {
	t.Helper()
	oldGrace, oldForce, oldPoll := syncStopGracePeriod, syncStopForceGracePeriod, syncStopPollInterval
	syncStopGracePeriod = grace
	syncStopForceGracePeriod = forceGrace
	syncStopPollInterval = poll
	t.Cleanup(func() {
		syncStopGracePeriod = oldGrace
		syncStopForceGracePeriod = oldForce
		syncStopPollInterval = oldPoll
	})
}

// captureStdout runs fn with os.Stdout redirected to a pipe and returns
// everything written to it. runSyncStop prints its user-facing progress
// directly via fmt.Printf (no injected io.Writer to a cobra command), so
// this is the only way a test can observe that printed text.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	require.NoError(t, err)

	old := os.Stdout
	os.Stdout = w
	fn()
	os.Stdout = old

	require.NoError(t, w.Close())
	var buf bytes.Buffer
	_, err = io.Copy(&buf, r)
	require.NoError(t, err)
	require.NoError(t, r.Close())
	return buf.String()
}

// TestRunSyncStop_TimeoutReportsForceHint pins the brief's item 1: a
// daemon that does not exit within the grace period gets the PID and the
// --force hint printed, and the call returns a non-zero error, without
// removing the pid file (the daemon may still be alive and shutting down).
func TestRunSyncStop_TimeoutReportsForceHint(t *testing.T) {
	setSyncStopGraces(t, 300*time.Millisecond, 300*time.Millisecond, 20*time.Millisecond)
	cfg, pidPath := syncStopTestConfig(t)

	helper, lines := startSyncStopHelper(t)
	defer func() { _ = helper.Process.Kill() }() // safety net regardless of assertion outcome
	waitForSyncStopHelperReady(t, lines)
	writeFakePIDFile(t, pidPath, helper.Process.Pid)

	var err error
	stdout := captureStdout(t, func() {
		err = runSyncStop(cfg, false)
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "did not exit within")
	assert.Contains(t, stdout, "run 'watchtower sync stop --force' to kill it",
		"the printed hint must actually name the --force escalation, not just the returned error")

	// The daemon never acknowledged SIGTERM, so the pid file must stay —
	// removing it here would make a later `sync stop` think nothing is
	// running while the process is still alive.
	_, statErr := os.Stat(pidPath)
	assert.NoError(t, statErr, "pid file should still exist after a timeout")

	// The helper is still alive: confirm via signal 0, then clean up.
	assert.NoError(t, syscall.Kill(helper.Process.Pid, 0), "helper should still be running after a plain (non-force) timeout")
	_ = helper.Process.Kill()
	_, _ = helper.Process.Wait()
}

// TestRunSyncStop_ForceKillsStuckDaemon pins the brief's item 2: against a
// daemon that swallows SIGTERM entirely, `sync stop --force` escalates all
// the way to SIGKILL, the process is gone, and the stale pid file is
// removed.
func TestRunSyncStop_ForceKillsStuckDaemon(t *testing.T) {
	setSyncStopGraces(t, 200*time.Millisecond, 200*time.Millisecond, 20*time.Millisecond)
	cfg, pidPath := syncStopTestConfig(t)

	helper, lines := startSyncStopHelper(t)
	defer func() { _ = helper.Process.Kill() }() // safety net if an assertion below fails first
	waitForSyncStopHelperReady(t, lines)
	writeFakePIDFile(t, pidPath, helper.Process.Pid)

	// The helper is our own child, so once SIGKILL lands it becomes a
	// zombie — still "alive" to kill(pid, 0) — until reaped. Reap it
	// concurrently with runSyncStop's polling, exactly as an init/launchd
	// parent would in production (where the stopping CLI is never the
	// daemon's parent, so this reaping race does not exist for real).
	//
	// Drain the scanner's line channel to completion before calling Wait():
	// os/exec forbids calling Cmd.Wait while a StdoutPipe reader is still
	// active (Wait closes the pipe as part of cleanup, racing the scanner's
	// own read). The channel closes on its own once the helper's stdout
	// hits EOF, which — since the helper never closes stdout itself — only
	// happens once the process actually exits, so draining first never
	// changes what this test observes.
	waitCh := make(chan error, 1)
	go func() {
		for range lines {
		}
		waitCh <- helper.Wait()
	}()

	err := runSyncStop(cfg, true)
	require.NoError(t, err)

	_, statErr := os.Stat(pidPath)
	assert.True(t, os.IsNotExist(statErr), "pid file should be removed once the daemon is confirmed dead")

	select {
	case waitErr := <-waitCh:
		exitErr, ok := waitErr.(*exec.ExitError)
		require.True(t, ok, "expected the helper to die by signal, got err=%v", waitErr)
		status, ok := exitErr.Sys().(syscall.WaitStatus)
		require.True(t, ok)
		assert.True(t, status.Signaled() && status.Signal() == syscall.SIGKILL,
			"expected the helper killed by SIGKILL, got signaled=%v signal=%v", status.Signaled(), status.Signal())
	case <-time.After(2 * time.Second):
		t.Fatal("helper process vanished but Wait never returned")
	}
}

// TestRunSyncStop_ForceNoDaemonRunning pins the brief's degenerate case:
// --force against a workspace with no pid file at all must not try to
// signal anything — it is a clean "not running" exit, same as plain
// `sync stop`.
func TestRunSyncStop_ForceNoDaemonRunning(t *testing.T) {
	cfg, _ := syncStopTestConfig(t)

	err := runSyncStop(cfg, true)
	assert.NoError(t, err)
}

// TestForceStopSync_ReVerifiesIdentityBeforeEscalating pins the fix for the
// PID-reuse gap in forceStopSync: pid is resolved once, up to
// syncStopGracePeriod ago, and the OS is free to reap the daemon and hand
// its pid to an unrelated process during either subsequent grace-period
// wait. A real test cannot force true PID reuse deterministically, so it
// uses the injected verifyDaemonAlive seam to simulate "the re-check says
// this pid is no longer our daemon" — and then proves, against a REAL
// still-alive helper process holding that exact pid, that forceStopSync
// never signals it once the seam reports it gone: with the re-check
// removed, forceStopSync would blindly send a second SIGTERM (swallowed,
// same as the stuck-daemon helper) and then SIGKILL, which — since this is
// the actual live process, not a reused pid — would really kill it.
func TestForceStopSync_ReVerifiesIdentityBeforeEscalating(t *testing.T) {
	setSyncStopGraces(t, 100*time.Millisecond, 100*time.Millisecond, 10*time.Millisecond)
	cfg, pidPath := syncStopTestConfig(t)

	helper, lines := startSyncStopHelper(t)
	defer func() { _ = helper.Process.Kill() }() // safety net regardless of assertion outcome
	waitForSyncStopHelperReady(t, lines)
	writeFakePIDFile(t, pidPath, helper.Process.Pid)

	oldVerify := verifyDaemonAlive
	verifyDaemonAlive = func(string, int) bool { return false }
	t.Cleanup(func() { verifyDaemonAlive = oldVerify })

	waitCh := make(chan error, 1)
	go func() {
		for range lines {
			// Drain remaining stdout before Wait() so we never call it
			// concurrently with the scanner goroutine still reading the
			// pipe (os/exec forbids that).
		}
		waitCh <- helper.Wait()
	}()

	err := runSyncStop(cfg, true)
	require.NoError(t, err, "forceStopSync must treat a re-check failure as a clean stop, not an error")

	// The helper must still be alive and untouched: nothing signalled it
	// beyond the very first (swallowed) SIGTERM runSyncStop always sends
	// before ever reaching forceStopSync.
	select {
	case waitErr := <-waitCh:
		t.Fatalf("helper exited (err=%v) — forceStopSync must not signal a pid the identity re-check reports gone", waitErr)
	case <-time.After(300 * time.Millisecond):
		// Still running, as expected.
	}
	assert.NoError(t, syscall.Kill(helper.Process.Pid, 0), "helper should still be running once the re-check reports the pid gone")

	_ = helper.Process.Kill()
	<-waitCh
}

// TestForceStopSync_ReVerifiesIdentityBeforeSIGKILLSpecifically pins the
// SECOND of forceStopSync's two verifyDaemonAlive checks in isolation — the
// one immediately before SIGKILL. TestForceStopSync_ReVerifiesIdentityBeforeEscalating
// above stubs the seam to a constant false, so its very first check (before
// the second SIGTERM) already returns and forceStopSync never reaches the
// second call at all; that test alone cannot tell "the pre-SIGKILL check
// exists" from "no check exists there but the first one already stopped
// us." Here the seam is stateful: true on the 1st call (before the second
// SIGTERM, which the helper swallows same as always) and false on the 2nd
// (before SIGKILL) — so escalation must reach and be stopped by THIS
// specific check, proven against the real still-alive helper never
// receiving SIGKILL.
func TestForceStopSync_ReVerifiesIdentityBeforeSIGKILLSpecifically(t *testing.T) {
	setSyncStopGraces(t, 100*time.Millisecond, 100*time.Millisecond, 10*time.Millisecond)
	cfg, pidPath := syncStopTestConfig(t)

	helper, lines := startSyncStopHelper(t)
	defer func() { _ = helper.Process.Kill() }() // safety net regardless of assertion outcome
	waitForSyncStopHelperReady(t, lines)
	writeFakePIDFile(t, pidPath, helper.Process.Pid)

	var calls atomic.Int32
	oldVerify := verifyDaemonAlive
	verifyDaemonAlive = func(string, int) bool {
		return calls.Add(1) == 1
	}
	t.Cleanup(func() { verifyDaemonAlive = oldVerify })

	waitCh := make(chan error, 1)
	go func() {
		for range lines {
		}
		waitCh <- helper.Wait()
	}()

	err := runSyncStop(cfg, true)
	require.NoError(t, err, "forceStopSync must treat the pre-SIGKILL re-check failure as a clean stop, not an error")

	assert.Equal(t, int32(2), calls.Load(), "expected exactly two identity re-checks: before the second SIGTERM and before SIGKILL")

	// The helper received the second SIGTERM (swallowed, as always) but
	// must NOT have been SIGKILLed once the second check reported it gone.
	select {
	case waitErr := <-waitCh:
		t.Fatalf("helper exited (err=%v) — SIGKILL must not fire once the pre-SIGKILL re-check reports the pid gone", waitErr)
	case <-time.After(300 * time.Millisecond):
		// Still running, as expected.
	}
	assert.NoError(t, syscall.Kill(helper.Process.Pid, 0), "helper should still be running once the pre-SIGKILL re-check reports the pid gone")

	_ = helper.Process.Kill()
	<-waitCh
}

// TestRunSyncStop_PlainStopRemovesPIDFileOnCleanExit is a regression pin for
// the plain (non-force) success path after the fix below: a daemon that
// exits within the grace period on the first SIGTERM still gets its pid
// file removed and "Daemon stopped." printed, with a nil error — the same
// outcome as before, now reached via verifyDaemonAlive's re-check rather
// than an unconditional RemovePID.
func TestRunSyncStop_PlainStopRemovesPIDFileOnCleanExit(t *testing.T) {
	setSyncStopGraces(t, 2*time.Second, 2*time.Second, 20*time.Millisecond)
	cfg, pidPath := syncStopTestConfig(t)

	helper, lines := startSyncStopDelayedHelper(t)
	defer func() { _ = helper.Process.Kill() }() // safety net regardless of assertion outcome
	waitForSyncStopHelperReady(t, lines)
	writeFakePIDFileWithTimestamp(t, pidPath, helper.Process.Pid)

	waitCh := drainAndReap(helper, lines)

	var err error
	stdout := captureStdout(t, func() {
		err = runSyncStop(cfg, false)
	})
	require.NoError(t, err)
	assert.Contains(t, stdout, "Daemon stopped.")

	_, statErr := os.Stat(pidPath)
	assert.True(t, os.IsNotExist(statErr), "pid file should be removed once the daemon is confirmed dead")

	select {
	case waitErr := <-waitCh:
		assert.NoError(t, waitErr, "the delayed helper exits cleanly on its own")
	case <-time.After(2 * time.Second):
		t.Fatal("helper never exited")
	}
}

// TestRunSyncStop_PlainStopSparesFreshDaemonThatWonTheRace pins the fix for
// runSyncStop's plain-stop path: once the original daemon is confirmed gone,
// it must not unconditionally RemovePID. Between SIGTERM landing and the
// process actually exiting — the delayed helper's built-in gap — a FRESH,
// unrelated daemon can start and claim the same pid file path. This test
// simulates exactly that by swapping the pid file to a second, live,
// correctly time-stamped helper mid-wait. The plain stop must still report
// success (the daemon it was asked to stop did stop) but must leave the
// second daemon's pid file untouched and must never signal it.
func TestRunSyncStop_PlainStopSparesFreshDaemonThatWonTheRace(t *testing.T) {
	setSyncStopGraces(t, 2*time.Second, 2*time.Second, 20*time.Millisecond)
	cfg, pidPath := syncStopTestConfig(t)

	original, originalLines := startSyncStopDelayedHelper(t)
	defer func() { _ = original.Process.Kill() }()
	waitForSyncStopHelperReady(t, originalLines)
	writeFakePIDFileWithTimestamp(t, pidPath, original.Process.Pid)

	fresh, freshLines := startSyncStopDelayedHelper(t)
	defer func() { _ = fresh.Process.Kill() }()
	waitForSyncStopHelperReady(t, freshLines)

	// Swap the pid file to the "fresh daemon" partway through the original
	// helper's 300ms post-SIGTERM delay — well before waitForProcessExit's
	// 20ms polling can notice the original has died, and well before it
	// actually does.
	swapped := make(chan struct{})
	go func() {
		time.Sleep(100 * time.Millisecond)
		writeFakePIDFileWithTimestamp(t, pidPath, fresh.Process.Pid)
		close(swapped)
	}()

	origWait := drainAndReap(original, originalLines)

	err := runSyncStop(cfg, false)
	require.NoError(t, err)
	<-swapped // the swap must have already happened for this assertion to mean anything

	data, statErr := os.ReadFile(pidPath)
	require.NoError(t, statErr, "a live, correctly-identified daemon's pid file must not be removed")
	assert.Contains(t, string(data), strconv.Itoa(fresh.Process.Pid))

	assert.NoError(t, syscall.Kill(fresh.Process.Pid, 0), "the fresh daemon must never have been signalled")

	select {
	case waitErr := <-origWait:
		assert.NoError(t, waitErr, "the original delayed helper exits cleanly on its own")
	case <-time.After(2 * time.Second):
		t.Fatal("original helper never exited")
	}

	freshWait := drainAndReap(fresh, freshLines)
	_ = fresh.Process.Kill()
	select {
	case <-freshWait:
	case <-time.After(2 * time.Second):
		t.Fatal("fresh helper never reaped")
	}
}
