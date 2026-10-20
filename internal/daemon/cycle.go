package daemon

import (
	"context"
	"net/http"
	"time"

	"watchtower/internal/slack"
)

// wakeSettleDelay is how long the loop waits after a detected sleep before it
// syncs again: Wi-Fi gets to reconnect, and the timer runs on the monotonic
// clock, so a DarkWake (Power Nap), which gives the process a few seconds
// before the Mac sleeps again, never starts a cycle — the wait simply carries
// on into the next real wake. A var so tests can shorten it.
var wakeSettleDelay = 15 * time.Second

// syncCycle is one runSync running in its own goroutine under its own
// context, so the loop stays responsive while it runs and can cancel it.
type syncCycle struct {
	cancel context.CancelFunc
	done   chan struct{} // closed once runSync has returned
	// resetTicker makes the next poll a full interval after this cycle ends
	// (the initial, wake and trigger cycles).
	resetTicker bool
	// interrupted is set when a detected sleep cancelled the cycle. Touched
	// only by the loop goroutine.
	interrupted bool
}

// startCycle runs runSync in a goroutine under a context derived from ctx, so
// a daemon shutdown cancels it too.
func (d *Daemon) startCycle(ctx context.Context, resetTicker bool) *syncCycle {
	cycleCtx, cancel := context.WithCancel(ctx)
	c := &syncCycle{cancel: cancel, done: make(chan struct{}), resetTicker: resetTicker}
	go func() {
		defer close(c.done)
		defer cancel()
		d.runSync(cycleCtx)
	}()
	return c
}

// runLoop runs the initial cycle, then one cycle per poll tick, manual trigger
// and (with sync.sync_on_wake) wake, never two at once. It returns once ctx is
// cancelled and the running cycle, if any, has returned.
//
// A sleep detected while a cycle runs cancels it, whatever sync_on_wake says:
// Go's timeouts count awake time only, so a request caught by a sleep can
// hang for half an hour of wall time across Power Nap wakes, and the cycle
// would then run its pipelines on data its failed syncs never refreshed. The
// cancelled cycle skips its pipelines (runSync); the loop waits for it to
// return, drops the pooled connections the sleep may have killed, and after
// wakeSettleDelay starts a fresh cycle (sync_on_wake on) or lets the next
// tick run one (off). A sleep while the loop is idle takes the same path minus
// the cancel. Another sleep during the delay starts the delay over. Ticks and
// triggers are not read while a cycle runs or the delay counts down, so they
// wait (collapsed into one) and are served right after.
func (d *Daemon) runLoop(ctx context.Context, pollInterval time.Duration) error {
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	// The initial cycle, right away.
	cycle := d.startCycle(ctx, true)
	var settle *time.Timer // the post-wake delay, nil when not counting down
	defer func() {
		if settle != nil {
			settle.Stop()
		}
	}()

	for {
		var cycleDone <-chan struct{}
		var settleC <-chan time.Time
		var tickC <-chan time.Time
		var triggerC <-chan struct{}
		switch {
		case cycle != nil:
			cycleDone = cycle.done
		case settle != nil:
			settleC = settle.C
		default:
			tickC = ticker.C
			triggerC = d.triggerChannel()
		}

		select {
		case <-ctx.Done():
			// The cycle's context derives from ctx: it is already cancelled.
			if cycle != nil {
				<-cycle.done
			}
			d.logger.Println("shutting down")
			return nil
		case <-cycleDone:
			finished := cycle
			cycle = nil
			if finished.interrupted {
				dropPooledConnections()
				settle = time.NewTimer(wakeSettleDelay)
				continue
			}
			if finished.resetTicker {
				ticker.Reset(pollInterval)
			}
		case <-settleC:
			settle = nil
			if d.config.Sync.SyncOnWake {
				d.logger.Println("syncing after wake")
				cycle = d.startCycle(ctx, true)
			}
		case <-tickC:
			cycle = d.startCycle(ctx, false)
		// Both watchers close their channel once ctx is cancelled, and a closed
		// channel is always ready in a select — without the ok check the loop
		// would keep drawing "events" and re-entering runSync on the dead ctx
		// until the random select pick landed on ctx.Done(). A closed watcher
		// is dropped (nil blocks forever) so only ctx.Done() remains.
		case slept, ok := <-d.wakeChannel():
			if !ok {
				d.wakeCh = nil
				continue
			}
			sleptFor := slept.Round(time.Second)
			switch {
			case cycle != nil:
				if !cycle.interrupted {
					d.logger.Printf("sleep detected (slept ~%s), cancelling the running cycle", sleptFor)
					cycle.interrupted = true
					cycle.cancel()
				}
			case settle != nil:
				d.logger.Printf("sleep detected (slept ~%s), starting the %s post-wake wait over", sleptFor, wakeSettleDelay)
				dropPooledConnections()
				settle.Reset(wakeSettleDelay)
			default:
				d.logger.Printf("sleep detected (slept ~%s), waiting %s for the network", sleptFor, wakeSettleDelay)
				dropPooledConnections()
				settle = time.NewTimer(wakeSettleDelay)
			}
		case _, ok := <-triggerC:
			if !ok {
				d.triggerCh = nil
				continue
			}
			d.logger.Println("manual sync trigger received, syncing")
			cycle = d.startCycle(ctx, true)
		}
	}
}

// dropPooledConnections closes the idle pooled HTTP connections a sleep may
// have left dead, so the next cycle dials afresh: http.DefaultTransport's —
// every integration whose client leaves Transport nil, and the oauth2 clients
// layered on it — and the Slack clients' shared transport.
func dropPooledConnections() {
	if tr, ok := http.DefaultTransport.(*http.Transport); ok {
		tr.CloseIdleConnections()
	}
	slack.CloseIdleConnections()
}
