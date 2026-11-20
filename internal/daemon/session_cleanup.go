package daemon

import (
	"context"
	"time"
)

// The automatic cleanup of ended workbench sessions (board #2131): at most
// once per sessionCleanupEvery, the cycle runs one pass of the session
// cleanup (sessioncleanup.AutoRun, wired by cmd), bounded by
// sessionCleanupBudget. The pass logs its own lines; a cancelled ctx stops
// it between two removals, and every item is re-checked when the next pass
// runs.
const (
	sessionCleanupEvery  = time.Hour
	sessionCleanupBudget = 10 * time.Minute
)

// SetSessionCleanup gives the daemon its automatic session-cleanup pass.
func (d *Daemon) SetSessionCleanup(pass func(ctx context.Context)) { d.sessionCleanup = pass }

// phaseSessionCleanup runs the pass when one is set and the last one is
// sessionCleanupEvery old (the first cycle runs it).
func (d *Daemon) phaseSessionCleanup(ctx context.Context) {
	if d.sessionCleanup == nil || ctx.Err() != nil {
		return
	}
	now := time.Now()
	if !d.sessionCleanupAt.IsZero() && now.Sub(d.sessionCleanupAt) < sessionCleanupEvery {
		return
	}
	d.sessionCleanupAt = now
	pctx, cancel := context.WithTimeout(ctx, sessionCleanupBudget)
	defer cancel()
	d.sessionCleanup(pctx)
}
