package cmd

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
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

// waitForLine reads scanned lines until it sees want or deadline passes —
// a deadline, not a spin-count, per the project's flake-prone
// spin-counter-vs-deadline lesson for external-process test waits.
func waitForLine(t *testing.T, lines <-chan string, want string, deadline time.Duration) {
	t.Helper()

	timeout := time.After(deadline)
	for {
		select {
		case line, ok := <-lines:
			if !ok {
				t.Fatalf("helper process closed stdout before printing %q", want)
			}
			if line == want {
				return
			}
		case <-timeout:
			t.Fatalf("timed out after %s waiting for helper to print %q", deadline, want)
		}
	}
}

// TestShutdownContext_SecondSignalTerminates pins the RCA §6b fix: a
// command stuck in a ctx-blind step (never returns after the first signal)
// must still die on a SECOND SIGTERM, instead of the signal being silently
// queued by the still-registered signal.NotifyContext notification.
func TestShutdownContext_SecondSignalTerminates(t *testing.T) {
	helper, lines := startShutdownHelper(t, "block")
	defer func() { _ = helper.Process.Kill() }() // safety net if an assertion below fails first

	waitForLine(t, lines, "ready", 5*time.Second)

	if err := helper.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("sending first SIGTERM: %v", err)
	}
	// The first signal must still cancel ctx normally — the helper's own
	// business logic (not notifyShutdownContext) is what prints this.
	waitForLine(t, lines, "cancelled", 2*time.Second)

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
	// Retrying on a short tick until either the deadline or exit — rather
	// than sending exactly once — asserts the fix's actual guarantee
	// (a repeat signal eventually kills) without gambling on a fixed sleep.
	deadline := time.After(2 * time.Second)
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
			continue
		case <-deadline:
			t.Fatal("helper did not exit despite repeated SIGTERM — the second signal is still being swallowed")
		}
	}

	select {
	case err := <-waitCh:
		assertKilledBySIGTERM(t, err)
	case <-time.After(2 * time.Second):
		t.Fatal("helper process vanished (Signal failed) but Wait never returned")
	}
}

func assertKilledBySIGTERM(t *testing.T, err error) {
	t.Helper()
	exitErr, ok := err.(*exec.ExitError)
	if !ok {
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

	waitForLine(t, lines, "ready", 5*time.Second)

	if err := helper.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("sending SIGTERM: %v", err)
	}
	waitForLine(t, lines, "cancelled", 2*time.Second)
	waitForLine(t, lines, "deferred", 2*time.Second)

	// Drain the scanner's line channel before calling Wait() (see the
	// comment in TestShutdownContext_SecondSignalTerminates) — the helper
	// exits right after printing "deferred", so this returns promptly.
	waitCh := make(chan error, 1)
	go func() {
		for range lines {
		}
		waitCh <- helper.Wait()
	}()

	select {
	case err := <-waitCh:
		if err != nil {
			t.Fatalf("helper did not exit cleanly after a single signal: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("helper did not return within 2s of the single SIGTERM")
	}
}

// TestNotifyShutdownContext_CallerCancelSuppressesLog pins the
// stoppedByCaller flag, in-process (no helper subprocess needed — this is
// about which code path logf runs on, not about real signal delivery). The
// caller's own returned cancel() is an ordinary graceful stop (e.g. a
// `defer cancel()` at ordinary command completion), not "shutdown
// requested" by an operator signal, so logf must never fire for it.
func TestNotifyShutdownContext_CallerCancelSuppressesLog(t *testing.T) {
	logged := make(chan struct{}, 1)
	logf := func(string, ...any) {
		select {
		case logged <- struct{}{}:
		default:
		}
	}

	ctx, cancel := notifyShutdownContext(context.Background(), logf)
	cancel()
	<-ctx.Done()

	select {
	case <-logged:
		t.Fatal("logf fired for a caller-initiated cancel; stoppedByCaller must suppress it — logf is only for an actual OS signal")
	case <-time.After(200 * time.Millisecond):
		// notifyShutdownContext's background goroutine unblocks the
		// instant ctx.Done() fires (already true above) and does nothing
		// else blocking before its logf check, so this window is ample
		// time for a regression to have logged by now.
	}
}
