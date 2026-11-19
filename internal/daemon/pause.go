package daemon

import (
	"context"
	"time"
)

// pauseRecheck is how often a paused or pausable runner (the automations
// scheduler, the plan-usage poller) asks SetSyncPaused's func again.
const pauseRecheck = 5 * time.Second

// SetSyncPaused sets the pause the daemon reads before each start: while
// paused returns true no sync cycle starts (a running one finishes), the
// startup calendar sync is skipped, the automations scheduler (no scheduled
// run) and the plan-usage poll are stopped. The executor, and with it Run
// Now and approval apply, keeps running. runSyncDaemon composes it from
// --no-sync and the owner's pause file (tower.IsPaused). Call it before Run.
func (d *Daemon) SetSyncPaused(paused func() bool) {
	d.syncPaused = paused
}

// isSyncPaused reports the pause now; false when none is set.
func (d *Daemon) isSyncPaused() bool {
	return d.syncPaused != nil && d.syncPaused()
}

// runUnlessPaused runs run while sync is not paused, until ctx ends or run
// returns on its own (its error is logged under name). It asks the pause
// every pauseRecheck: a pause cancels run's context and waits for it, and a
// resume starts it afresh. With no pause set, run just runs.
func (d *Daemon) runUnlessPaused(ctx context.Context, name string, run func(context.Context) error) {
	if d.syncPaused == nil {
		if err := run(ctx); err != nil {
			d.logger.Printf("%s stopped: %v", name, err)
		}
		return
	}
	recheck := time.NewTicker(pauseRecheck)
	defer recheck.Stop()
	for {
		if d.isSyncPaused() {
			d.logger.Printf("%s held: sync paused", name)
			for d.isSyncPaused() {
				select {
				case <-ctx.Done():
					return
				case <-recheck.C:
				}
			}
			d.logger.Printf("%s resumed", name)
		}
		runCtx, cancel := context.WithCancel(ctx)
		done := make(chan error, 1)
		go func() { done <- run(runCtx) }()
		paused := false
		for !paused {
			select {
			case <-ctx.Done():
				cancel()
				<-done
				return
			case err := <-done:
				cancel()
				if err != nil {
					d.logger.Printf("%s stopped: %v", name, err)
				}
				return
			case <-recheck.C:
				paused = d.isSyncPaused()
			}
		}
		cancel()
		<-done
	}
}
