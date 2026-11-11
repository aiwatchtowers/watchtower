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
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"
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
// SIGKILL — which cannot be caught or ignored — ever ends it. It prints
// "swallowed" for every SIGTERM it handled, so a test knows the signal
// arrived and the process chose to live on. Run the ordinary way (no env
// var set) it is a silent no-op.
func TestSyncStop_HelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}

	sigCh := make(chan os.Signal, 8)
	signal.Notify(sigCh, syscall.SIGTERM)
	go func() {
		for range sigCh {
			// Swallow every SIGTERM — never exit on it.
			fmt.Println("swallowed")
		}
	}()

	fmt.Println("ready")
	select {}
}

// TestSyncStop_DelayedHelperProcess is another helper subprocess (same
// re-exec pattern as TestSyncStop_HelperProcess) that exits some time after
// receiving SIGTERM instead of instantly (a plain `sleep`) or never (the
// "stuck daemon" helper above) — giving a test a window in which the
// process is still alive-but-dying, to mutate state during. It prints
// "signalled" the instant it receives SIGTERM and then exits only once the
// test writes a line to its stdin, so the window is the test's to end,
// not a clock's. Run the ordinary way (no env var set) it is a silent no-op.
func TestSyncStop_DelayedHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS_DELAYED") != "1" {
		return
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM)

	fmt.Println("ready")
	<-sigCh
	fmt.Println("signalled")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
	os.Exit(0)
}

// stopHelper is one helper process: its stdout lines after "ready", and
// its exit, reaped exactly once.
type stopHelper struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	events chan string   // stdout lines after "ready"; closed at EOF
	done   chan struct{} // closed once Wait returned
	err    error         // Wait's result; read after done
	// onSignalled ends a delayed helper's alive-but-dying window; the
	// default lets it exit at once.
	onSignalled func()
}

// startStopHelper re-execs the test binary into the helper named by
// testName with env set, waits for its "ready" line and registers a
// cleanup that kills and reaps it.
func startStopHelper(t *testing.T, testName, env string) *stopHelper {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^"+testName+"$")
	cmd.Env = append(os.Environ(), env+"=1")
	cmd.Stderr = os.Stderr
	stdin, err := cmd.StdinPipe()
	require.NoError(t, err)
	stdout, err := cmd.StdoutPipe()
	require.NoError(t, err)
	require.NoError(t, cmd.Start())
	h := &stopHelper{cmd: cmd, stdin: stdin, events: make(chan string, 64), done: make(chan struct{})}
	h.onSignalled = h.release
	ready := make(chan bool, 1)
	go func() {
		defer close(h.done)
		sc := bufio.NewScanner(stdout)
		ready <- sc.Scan() && sc.Text() == "ready"
		for sc.Scan() {
			h.events <- sc.Text()
		}
		close(h.events)
		// Wait only after stdout is drained (exec.Cmd's rule for StdoutPipe).
		h.err = cmd.Wait()
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-h.done
	})
	require.True(t, <-ready, "the helper did not report ready")
	return h
}

func startStuckHelper(t *testing.T) *stopHelper {
	return startStopHelper(t, "TestSyncStop_HelperProcess", "GO_WANT_HELPER_PROCESS")
}

func startDelayedHelper(t *testing.T) *stopHelper {
	return startStopHelper(t, "TestSyncStop_DelayedHelperProcess", "GO_WANT_HELPER_PROCESS_DELAYED")
}

// release lets a delayed helper exit.
func (h *stopHelper) release() { _, _ = io.WriteString(h.stdin, "exit\n") }

// pid is the helper's process id.
func (h *stopHelper) pid() int { return h.cmd.Process.Pid }

// sentSignal is one signal the stop sent.
type sentSignal struct {
	pid int
	sig syscall.Signal
}

// stopRecorder replaces the stop's two process seams for one test: every
// signal is recorded and then really sent (the helper's handling is part of
// what is tested), and every grace-period wait is resolved by the helper's
// next event — "swallowed" (it handled the SIGTERM and lives on: the grace
// would run out), "signalled" (a delayed helper starts dying; its
// onSignalled ends the window) or its exit (reaped: the wait succeeds).
type stopRecorder struct {
	mu      sync.Mutex
	signals []sentSignal
	graces  []time.Duration
}

func recordStop(t *testing.T, helpers ...*stopHelper) *stopRecorder {
	t.Helper()
	r := &stopRecorder{}
	byPID := map[int]*stopHelper{}
	for _, h := range helpers {
		byPID[h.pid()] = h
	}
	prevKill, prevWait := syncStopKill, syncStopWaitExit
	t.Cleanup(func() { syncStopKill, syncStopWaitExit = prevKill, prevWait })
	syncStopKill = func(pid int, sig syscall.Signal) error {
		r.mu.Lock()
		r.signals = append(r.signals, sentSignal{pid, sig})
		r.mu.Unlock()
		return syscall.Kill(pid, sig)
	}
	syncStopWaitExit = func(pid int, grace time.Duration) bool {
		r.mu.Lock()
		r.graces = append(r.graces, grace)
		r.mu.Unlock()
		h, ok := byPID[pid]
		if !ok {
			t.Errorf("waited for pid %d, which is no helper of this test", pid)
			return false
		}
		for line := range h.events {
			switch line {
			case "swallowed":
				return false
			case "signalled":
				h.onSignalled()
			}
		}
		<-h.done
		return true
	}
	return r
}

// sent is a copy of the signals sent so far.
func (r *stopRecorder) sent() []sentSignal {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]sentSignal(nil), r.signals...)
}

// waited is a copy of the grace periods waited out so far.
func (r *stopRecorder) waited() []time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]time.Duration(nil), r.graces...)
}

// TestWaitForProcessExit_PollsUntilGoneOrGrace pins the real wait the
// recorder replaces, on the synctest bubble's clock: a process that is gone
// ends it at once, and a live one (this test process) holds it for exactly
// the grace period.
func TestWaitForProcessExit_PollsUntilGoneOrGrace(t *testing.T) {
	gone := exec.Command("true")
	require.NoError(t, gone.Run()) // exited and reaped: its pid answers ESRCH
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		assert.True(t, waitForProcessExit(gone.Process.Pid, syncStopGracePeriod))
		assert.Zero(t, time.Since(start), "a gone process ends the wait at once")

		start = time.Now()
		assert.False(t, waitForProcessExit(os.Getpid(), syncStopGracePeriod))
		elapsed := time.Since(start)
		assert.GreaterOrEqual(t, elapsed, syncStopGracePeriod, "a live process holds the wait for the whole grace")
		assert.Less(t, elapsed, syncStopGracePeriod+syncStopPollInterval, "and not a poll longer")
	})
}

// syncStopTestConfig points a *config.Config at a fresh temp workspace and
// returns it plus the pid-file path runSyncStop will read/write.
func syncStopTestConfig(t *testing.T) (*config.Config, string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws"}
	return cfg, pidFilePath(cfg)
}

// writeFakePIDFile writes pid in the legacy (no-timestamp) pid-file format.
// daemon.resolveProcess treats a legacy file as confirmed via its 30-day
// mtime heuristic rather than the timestamp+comm identity check — exactly
// what these tests want, since a real helper subprocess here is never
// actually named "watchtower" (identifyProcess's comm factor would always
// call it reused). These tests care about signal/grace-period/cleanup
// flow, not identity-detection specifics, which internal/daemon's own
// pidfile tests cover directly with a stubbed reader.
func writeFakePIDFile(t *testing.T, path string, pid int) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(strconv.Itoa(pid)), 0o600))
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
	cfg, pidPath := syncStopTestConfig(t)

	helper := startStuckHelper(t)
	writeFakePIDFile(t, pidPath, helper.pid())
	rec := recordStop(t, helper)

	var err error
	stdout := captureStdout(t, func() {
		err = runSyncStop(cfg, false)
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "did not exit within "+syncStopGracePeriod.String())
	assert.Contains(t, stdout, "run 'watchtower sync stop --force' to kill it",
		"the printed hint must actually name the --force escalation, not just the returned error")
	assert.Equal(t, []sentSignal{{helper.pid(), syscall.SIGTERM}}, rec.sent(), "a plain stop sends one SIGTERM, never more")
	assert.Equal(t, []time.Duration{syncStopGracePeriod}, rec.waited())

	// The daemon never acknowledged SIGTERM, so the pid file must stay —
	// removing it here would make a later `sync stop` think nothing is
	// running while the process is still alive.
	_, statErr := os.Stat(pidPath)
	assert.NoError(t, statErr, "pid file should still exist after a timeout")

	// The helper is still alive: confirm via signal 0. t.Cleanup reaps it.
	assert.NoError(t, syscall.Kill(helper.pid(), 0), "helper should still be running after a plain (non-force) timeout")
}

// TestRunSyncStop_ForceKillsStuckDaemon pins the brief's item 2: against a
// daemon that swallows SIGTERM entirely, `sync stop --force` escalates all
// the way to SIGKILL, the process is gone, and the stale pid file is
// removed.
func TestRunSyncStop_ForceKillsStuckDaemon(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)

	helper := startStuckHelper(t)
	writeFakePIDFile(t, pidPath, helper.pid())
	rec := recordStop(t, helper)

	err := runSyncStop(cfg, true)
	require.NoError(t, err)

	_, statErr := os.Stat(pidPath)
	assert.True(t, os.IsNotExist(statErr), "pid file should be removed once the daemon is confirmed dead")
	assert.Equal(t, []sentSignal{{helper.pid(), syscall.SIGTERM}, {helper.pid(), syscall.SIGTERM}, {helper.pid(), syscall.SIGKILL}}, rec.sent())
	assert.Equal(t, []time.Duration{syncStopGracePeriod, syncStopForceGracePeriod, syncStopForceGracePeriod}, rec.waited())

	<-helper.done
	var exitErr *exec.ExitError
	require.ErrorAs(t, helper.err, &exitErr, "expected the helper to die by signal, got err=%v", helper.err)
	status, ok := exitErr.Sys().(syscall.WaitStatus)
	require.True(t, ok)
	assert.True(t, status.Signaled() && status.Signal() == syscall.SIGKILL,
		"expected the helper killed by SIGKILL, got signaled=%v signal=%v", status.Signaled(), status.Signal())
}

// TestRunSyncStop_ForceNoDaemonRunning pins the brief's degenerate case:
// --force against a workspace with no pid file at all must not try to
// signal anything — it is a clean "not running" exit, same as plain
// `sync stop`.
func TestRunSyncStop_ForceNoDaemonRunning(t *testing.T) {
	cfg, _ := syncStopTestConfig(t)
	rec := recordStop(t)

	err := runSyncStop(cfg, true)
	assert.NoError(t, err)
	assert.Empty(t, rec.sent())
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
	cfg, pidPath := syncStopTestConfig(t)

	helper := startStuckHelper(t)
	writeFakePIDFile(t, pidPath, helper.pid())
	rec := recordStop(t, helper)

	oldVerify := verifyDaemonAlive
	verifyDaemonAlive = func(string, int) bool { return false }
	t.Cleanup(func() { verifyDaemonAlive = oldVerify })

	err := runSyncStop(cfg, true)
	require.NoError(t, err, "forceStopSync must treat a re-check failure as a clean stop, not an error")

	// Nothing signalled the helper beyond the very first (swallowed)
	// SIGTERM runSyncStop always sends before ever reaching forceStopSync.
	assert.Equal(t, []sentSignal{{helper.pid(), syscall.SIGTERM}}, rec.sent(),
		"forceStopSync must not signal a pid the identity re-check reports gone")
	assert.NoError(t, syscall.Kill(helper.pid(), 0), "helper should still be running once the re-check reports the pid gone")
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
	cfg, pidPath := syncStopTestConfig(t)

	helper := startStuckHelper(t)
	writeFakePIDFile(t, pidPath, helper.pid())
	rec := recordStop(t, helper)

	var calls atomic.Int32
	oldVerify := verifyDaemonAlive
	verifyDaemonAlive = func(string, int) bool {
		return calls.Add(1) == 1
	}
	t.Cleanup(func() { verifyDaemonAlive = oldVerify })

	err := runSyncStop(cfg, true)
	require.NoError(t, err, "forceStopSync must treat the pre-SIGKILL re-check failure as a clean stop, not an error")

	assert.Equal(t, int32(2), calls.Load(), "expected exactly two identity re-checks: before the second SIGTERM and before SIGKILL")

	// The helper received the second SIGTERM (swallowed, as always) but
	// must NOT have been SIGKILLed once the second check reported it gone.
	assert.Equal(t, []sentSignal{{helper.pid(), syscall.SIGTERM}, {helper.pid(), syscall.SIGTERM}}, rec.sent(),
		"SIGKILL must not fire once the pre-SIGKILL re-check reports the pid gone")
	assert.NoError(t, syscall.Kill(helper.pid(), 0), "helper should still be running once the pre-SIGKILL re-check reports the pid gone")
}

// TestRunSyncStop_PlainStopRemovesPIDFileOnCleanExit is a regression pin for
// the plain (non-force) success path: a daemon that exits within the grace
// period on the first SIGTERM still gets its pid file removed and "Daemon
// stopped." printed, with a nil error — reached via reapPIDFile's
// daemon.FindProcess re-read rather than an unconditional RemovePID.
func TestRunSyncStop_PlainStopRemovesPIDFileOnCleanExit(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)

	helper := startDelayedHelper(t)
	writeFakePIDFile(t, pidPath, helper.pid())
	rec := recordStop(t, helper)

	var err error
	stdout := captureStdout(t, func() {
		err = runSyncStop(cfg, false)
	})
	require.NoError(t, err)
	assert.Contains(t, stdout, "Daemon stopped.")
	assert.Equal(t, []sentSignal{{helper.pid(), syscall.SIGTERM}}, rec.sent())

	_, statErr := os.Stat(pidPath)
	assert.True(t, os.IsNotExist(statErr), "pid file should be removed once the daemon is confirmed dead")

	<-helper.done
	assert.NoError(t, helper.err, "the delayed helper exits cleanly on its own")
}

// TestRunSyncStop_PlainStopSparesFreshDaemonThatWonTheRace pins the fix for
// runSyncStop's plain-stop path: once the original daemon is confirmed gone,
// it must not unconditionally RemovePID. Between SIGTERM landing and the
// process actually exiting — the delayed helper's alive-but-dying window —
// a FRESH, unrelated daemon can start and claim the same pid file path.
// This test does exactly that by swapping the pid file to a second, live
// helper inside that window, before the original exits. The plain stop
// must still report success (the daemon it was asked to stop did stop) but
// must leave the second daemon's pid file untouched and must never signal
// it — checked on the recorded signals, not on the fresh helper's
// liveness.
func TestRunSyncStop_PlainStopSparesFreshDaemonThatWonTheRace(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)

	original := startDelayedHelper(t)
	writeFakePIDFile(t, pidPath, original.pid())
	fresh := startDelayedHelper(t)
	rec := recordStop(t, original, fresh)

	// The original got its SIGTERM and is dying: the fresh daemon claims
	// the pid file, and only then does the original exit.
	original.onSignalled = func() {
		writeFakePIDFile(t, pidPath, fresh.pid())
		original.release()
	}

	err := runSyncStop(cfg, false)
	require.NoError(t, err)

	data, statErr := os.ReadFile(pidPath)
	require.NoError(t, statErr, "a live, correctly-identified daemon's pid file must not be removed")
	assert.Contains(t, string(data), strconv.Itoa(fresh.pid()))

	<-original.done
	assert.NoError(t, original.err, "the original delayed helper exits cleanly on its own")

	assert.Equal(t, []sentSignal{{original.pid(), syscall.SIGTERM}}, rec.sent(), "the fresh daemon must never have been signalled")
	assert.NoError(t, syscall.Kill(fresh.pid(), 0), "the fresh daemon is still running")
}
