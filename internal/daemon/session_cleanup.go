package daemon

import (
	"context"
	"time"
)

// The automatic cleanup of ended workbench sessions (board #2131): a
// goroutine of its own runs one pass of the session cleanup
// (sessioncleanup.AutoRun, wired by cmd) at start and then every
// sessionCleanupEvery, each bounded by sessionCleanupBudget — apart from the
// sync cycle, so a paused sync, --no-sync or a cancelled fetch never holds
// it back and a pass never delays the pipelines. One pass at a time: the
// next tick waits for the running one. The daemon's ctx stops it; a pass
// stopped part-way is re-checked from scratch by the next one.
const (
	sessionCleanupEvery  = time.Hour
	sessionCleanupBudget = 10 * time.Minute
)

// SetSessionCleanup gives the daemon its automatic session-cleanup pass.
func (d *Daemon) SetSessionCleanup(pass func(ctx context.Context)) { d.sessionCleanup = pass }

// startSessionCleanup starts the pass loop on an hourly ticker; the
// returned stop cancels it and waits for it. Nothing runs without a pass.
func (d *Daemon) startSessionCleanup(ctx context.Context) (stop func()) {
	if d.sessionCleanup == nil {
		return func() {}
	}
	runCtx, cancel := context.WithCancel(ctx)
	ticker := time.NewTicker(sessionCleanupEvery)
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer ticker.Stop()
		d.runSessionCleanup(runCtx, ticker.C)
	}()
	return func() {
		cancel()
		<-done
	}
}

// runSessionCleanup runs a pass now and then one per tick until ctx is
// done.
func (d *Daemon) runSessionCleanup(ctx context.Context, tick <-chan time.Time) {
	for {
		pctx, cancel := context.WithTimeout(ctx, sessionCleanupBudget)
		d.sessionCleanup(pctx)
		cancel()
		select {
		case <-ctx.Done():
			return
		case <-tick:
		}
	}
}
