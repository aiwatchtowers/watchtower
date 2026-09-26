package cmd

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
)

// notifyShutdownContext wraps signal.NotifyContext(parent, os.Interrupt,
// syscall.SIGTERM) for a long-running command, adding one guarantee plain
// signal.NotifyContext does not give: a SECOND SIGINT/SIGTERM always
// terminates the process outright, even while the step in progress never
// checks ctx.Err(). See the daemon-shutdown-hang RCA §3/§6b: a ctx-blind
// go-git call inside memory's semantic tier could run for hours, and while
// it did, every SIGTERM after the first was silently swallowed — the Go
// runtime treats a signal as "handled" for as long as its notification
// channel stays registered, and signal.NotifyContext alone only
// unregisters when the caller's own deferred cancel() finally runs, which
// is exactly what a stuck ctx-blind step prevents.
//
// notifyShutdownContext fixes that without changing the FIRST signal's
// behavior: it still just cancels ctx, same as calling signal.NotifyContext
// directly, so the caller's normal graceful-shutdown path (defers run,
// locks release, the pid file gets removed) is unaffected. A background
// goroutine unregisters the signal notification the instant a real signal
// cancels ctx, restoring the default terminate disposition immediately —
// so a repeat signal kills instead of queuing silently.
//
// logf receives one informational line when ctx is cancelled by an actual
// signal. It is not called when the caller's own returned cancel func runs
// first (e.g. a `defer cancel()` at ordinary command completion) or when
// parent is already done for an unrelated reason — neither is "shutdown
// requested," so neither should tell the operator to send a second signal.
// Pass silentShutdownLogf (below) for an interactive command where a plain
// Ctrl-C should just quit quietly instead of printing a force-stop hint;
// stderrLogf (also below) is the default for everything else.
//
// Note: the log line is best-effort, not guaranteed — if the caller's own
// cancel() races a real signal (e.g. the command finishes and returns right
// as SIGTERM arrives), stoppedByCaller may already be set and the line is
// silently dropped. This never affects shutdown correctness, only whether
// the operator sees the hint.
func notifyShutdownContext(parent context.Context, logf func(string, ...any)) (context.Context, context.CancelFunc) {
	ctx, stop := signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)

	var stoppedByCaller atomic.Bool
	cancel := func() {
		stoppedByCaller.Store(true)
		stop()
	}

	go func() {
		<-ctx.Done()
		if !stoppedByCaller.Load() && parent.Err() == nil {
			logf("shutdown requested; send the signal again to force")
		}
		stop()
	}()

	return ctx, cancel
}

// stderrLogf is the notifyShutdownContext logf for call sites with no
// dedicated logger of their own — stderr keeps the message clear of a
// command's stdout JSON/text protocol.
func stderrLogf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}

// silentShutdownLogf is the notifyShutdownContext logf for an interactive
// command a person runs directly in a terminal (`logs -f`, `ask`): a plain
// Ctrl-C there should just quit, not print "shutdown requested; send the
// signal again to force" — that hint is meant for a stuck daemon or batch
// command, not a person who just pressed the ordinary interrupt key once.
func silentShutdownLogf(string, ...any) {}
