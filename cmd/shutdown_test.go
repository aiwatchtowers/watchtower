package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	"github.com/spf13/cobra"
)

// TestShutdownContext_HelperProcess is not a real test: it is re-executed as
// a subprocess by the two tests below (the standard library's
// GO_WANT_HELPER_PROCESS re-exec pattern, e.g. os/exec's exec_test.go) so
// they can send it real OS signals and observe how the process actually
// dies. Run the ordinary way (no env var set) it is a silent no-op.
func TestShutdownContext_HelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}

	ctx, cancel := notifyShutdownContext(context.Background(), stderrLogf)
	defer cancel()

	switch mode := os.Getenv("GO_HELPER_SHUTDOWN_MODE"); mode {
	case "block":
		fmt.Println("ready")
		<-ctx.Done()
		fmt.Println("cancelled")
		// Simulate a ctx-blind step that never checks ctx.Err() again
		// (the shape of memory's pre-fix EvictEpisodes/AgeEpisodes loops)
		// — only an unregistered, default-disposition second signal ends
		// this process.
		select {}
	case "cleanup":
		defer fmt.Println("deferred")
		fmt.Println("ready")
		<-ctx.Done()
		fmt.Println("cancelled")
	default:
		fmt.Fprintf(os.Stderr, "unknown GO_HELPER_SHUTDOWN_MODE %q\n", mode)
		os.Exit(2)
	}
}

// startShutdownHelper re-execs the test binary into the helper process
// above, in the given mode, and streams its stdout lines back on a channel.
func startShutdownHelper(t *testing.T, mode string) (*exec.Cmd, <-chan string) {
	t.Helper()

	helper := exec.Command(os.Args[0], "-test.run=^TestShutdownContext_HelperProcess$")
	helper.Env = append(os.Environ(),
		"GO_WANT_HELPER_PROCESS=1",
		"GO_HELPER_SHUTDOWN_MODE="+mode,
	)
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

// waitForLine reads scanned lines until it sees want. It has no deadline
// of its own: a helper that never prints want and never exits hangs the
// run into go test's -timeout.
func waitForLine(t *testing.T, lines <-chan string, want string) {
	t.Helper()
	for line := range lines {
		if line == want {
			return
		}
	}
	t.Fatalf("helper process closed stdout before printing %q", want)
}

// TestShutdownContext_SecondSignalTerminates pins the RCA §6b fix: a
// command stuck in a ctx-blind step (never returns after the first signal)
// must still die on a SECOND SIGTERM, instead of the signal being silently
// queued by the still-registered signal.NotifyContext notification.
func TestShutdownContext_SecondSignalTerminates(t *testing.T) {
	helper, lines := startShutdownHelper(t, "block")
	defer func() { _ = helper.Process.Kill() }() // safety net if an assertion below fails first

	waitForLine(t, lines, "ready")

	if err := helper.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("sending first SIGTERM: %v", err)
	}
	// The first signal must still cancel ctx normally — the helper's own
	// business logic (not notifyShutdownContext) is what prints this.
	waitForLine(t, lines, "cancelled")

	// Drain the scanner's line channel to completion before calling Wait():
	// os/exec forbids calling Cmd.Wait while a StdoutPipe reader is still
	// active (Wait closes the pipe as part of cleanup, racing the
	// scanner's own read). The channel closes on its own once the
	// helper's stdout hits EOF — which, since "block" mode prints nothing
	// more and never closes stdout itself, only happens once the process
	// actually exits, so draining first never changes what this test
	// observes or waits for.
	waitCh := make(chan error, 1)
	go func() {
		for range lines {
		}
		waitCh <- helper.Wait()
	}()

	// There is an inherent, unavoidable race between the moment ctx is
	// cancelled (unblocking both the helper's own "cancelled" print and
	// notifyShutdownContext's background stop() goroutine) and the moment
	// that goroutine actually finishes unregistering the signal — a second
	// SIGTERM sent in that tiny window still lands on the old,
	// not-yet-unregistered channel and is harmlessly absorbed (matching
	// production: nothing is lost, a following signal still kills).
	// Retrying on a short tick until exit — rather than sending exactly
	// once — asserts the fix's actual guarantee (a repeat signal
	// eventually kills) without gambling on a fixed sleep. A second signal
	// that stays swallowed hangs the run into go test's -timeout.
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		if err := helper.Process.Signal(syscall.SIGTERM); err != nil {
			break // process is already gone; fall through to collect its exit below
		}
		select {
		case err := <-waitCh:
			assertKilledBySIGTERM(t, err)
			return
		case <-ticker.C:
		}
	}
	assertKilledBySIGTERM(t, <-waitCh)
}

func assertKilledBySIGTERM(t *testing.T, err error) {
	t.Helper()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("expected the helper to die by signal, got err=%v", err)
	}
	status, ok := exitErr.Sys().(syscall.WaitStatus)
	if !ok {
		t.Fatalf("ProcessState.Sys() is not a syscall.WaitStatus: %T", exitErr.Sys())
	}
	if !status.Signaled() || status.Signal() != syscall.SIGTERM {
		t.Fatalf("expected the helper killed by SIGTERM, got signaled=%v signal=%v", status.Signaled(), status.Signal())
	}
}

// TestShutdownContext_SingleSignalReturnsNormally pins the plan's Review
// Focus #4: the FIRST signal must still run an ordinary graceful shutdown
// (defers run) rather than killing the process outright.
func TestShutdownContext_SingleSignalReturnsNormally(t *testing.T) {
	helper, lines := startShutdownHelper(t, "cleanup")
	defer func() { _ = helper.Process.Kill() }() // safety net if an assertion below fails first

	waitForLine(t, lines, "ready")

	if err := helper.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("sending SIGTERM: %v", err)
	}
	waitForLine(t, lines, "cancelled")
	waitForLine(t, lines, "deferred")

	// Drain the scanner's line channel before calling Wait() (see the
	// comment in TestShutdownContext_SecondSignalTerminates) — the helper
	// exits right after printing "deferred", so this returns promptly.
	waitCh := make(chan error, 1)
	go func() {
		for range lines {
		}
		waitCh <- helper.Wait()
	}()

	if err := <-waitCh; err != nil {
		t.Fatalf("helper did not exit cleanly after a single signal: %v", err)
	}
}

// TestNotifyShutdownContext_CallerCancelSuppressesLog pins the
// stoppedByCaller flag, in-process (no helper subprocess needed — this is
// about which code path logf runs on, not about real signal delivery). The
// caller's own returned cancel() is an ordinary graceful stop (e.g. a
// `defer cancel()` at ordinary command completion), not "shutdown
// requested" by an operator signal, so logf must never fire for it.
func TestNotifyShutdownContext_CallerCancelSuppressesLog(t *testing.T) {
	// os/signal starts its process-wide watcher goroutine on the first
	// Notify; start it here, outside the bubble, so it is not the bubble's.
	c := make(chan os.Signal, 1)
	signal.Notify(c, syscall.SIGWINCH)
	signal.Stop(c)

	synctest.Test(t, func(t *testing.T) {
		var logged atomic.Int32
		ctx, cancel := notifyShutdownContext(context.Background(), func(string, ...any) { logged.Add(1) })
		cancel()
		<-ctx.Done()
		// Every goroutine of the bubble has finished or is blocked: the
		// background goroutine has made its logf decision.
		synctest.Wait()
		if n := logged.Load(); n != 0 {
			t.Fatalf("logf fired %d times for a caller-initiated cancel; stoppedByCaller must suppress it — logf is only for an actual OS signal", n)
		}
	})
}

// cancelAIChildOnSignal gives the command a context derived from its own
// (Background outside Execute) that its stop cancels; a signal cancels it
// the same way (notifyShutdownContext, tested above).
func TestCancelAIChildOnSignal_SetsACancellableContext(t *testing.T) {
	c := &cobra.Command{}
	stop := cancelAIChildOnSignal(c)
	ctx := c.Context()
	if ctx == nil || ctx.Err() != nil {
		t.Fatalf("context = %v, want a live one", ctx)
	}
	stop()
	if ctx.Err() == nil {
		t.Fatal("stop did not cancel the command's context")
	}
}
