package daemon

import (
	"context"
	"errors"
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

// manualRestartAfter is how long a cycle's Slack sync must have made no
// progress before a manual trigger cancels the cycle's source fetches and
// starts a fresh cycle at once. Only the Slack sync qualifies: it is the one
// fetch whose progress is visible while it runs (the sync heartbeat), and the
// one where a stall lasts — the other fetchers (calendars, mail, Jira,
// Linear, Confluence) run with 30 s client timeouts, so a dead socket clears
// itself. A Slack sync stalled that long most likely sits on a slow or dead
// connection, and the owner pressing Sync Now wants fresh data now; one still
// moving (a first sync) finishes on its own. Measured on the monotonic clock,
// so the time a Mac slept never counts as a stall.
const manualRestartAfter = 60 * time.Second

// cycleSection is where the running cycle is (Daemon.cycleSection): runSync
// moves it along, startCycle resets it, and runLoop reads it to decide what a
// sleep or a manual trigger does to the cycle.
type cycleSection int32

const (
	// sectionSlackFetch is the Slack sync, the one fetch a trigger may
	// restart (manualRestartAfter).
	sectionSlackFetch cycleSection = iota
	// sectionOtherFetch is every later source fetch: reaction commands,
	// calendars, mail, Jira, Linear, Confluence, agent analytics.
	sectionOtherFetch
	// sectionPipelines is the AI pipelines, which run on the daemon's
	// context and always finish.
	sectionPipelines
	// sectionBackfill is the history backfill, which runs on the fetch
	// context: a sleep cancels it, a trigger waits for it (its 5-minute
	// budget bounds the wait).
	sectionBackfill
)

func (d *Daemon) setSection(s cycleSection) { d.cycleSection.Store(int32(s)) }
func (d *Daemon) section() cycleSection     { return cycleSection(d.cycleSection.Load()) }

// The causes a cycle's fetch context is cancelled with, so the logs name what
// stopped it (fetchStopReason). A daemon shutdown cancels the parent context:
// its cause is context.Canceled.
var (
	errCycleSlept   = errors.New("the machine slept")
	errCycleRestart = errors.New("Sync Now restarted the cycle")
)

// fetchStopReason names what cancelled a cycle's fetch context, for the log.
func fetchStopReason(fetchCtx context.Context) string {
	switch cause := context.Cause(fetchCtx); {
	case errors.Is(cause, errCycleSlept):
		return "sleep"
	case errors.Is(cause, errCycleRestart):
		return "Sync Now restart"
	default:
		return "shutdown"
	}
}

// isLoopCancelErr is isBenignShutdownErr narrowed to the cancels the daemon
// makes itself: ctx was cancelled by runLoop (a sleep, a Sync Now restart) or
// by the shutdown — its cause says which, through any child contexts — and
// every leaf of err is context.Canceled. A deadline is never one: ctx's own,
// such as the history backfill's budget, or a call's timeout inside it is a
// failure, recorded as such.
func isLoopCancelErr(ctx context.Context, err error) bool {
	cause := context.Cause(ctx)
	if err == nil || (!errors.Is(cause, errCycleSlept) && !errors.Is(cause, errCycleRestart) &&
		!errors.Is(cause, context.Canceled)) {
		return false
	}
	leaves := []error{err}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		leaves = joined.Unwrap()
	}
	for _, e := range leaves {
		if !errors.Is(e, context.Canceled) {
			return false
		}
	}
	return len(leaves) > 0
}

// syncCycle is one runSync running in its own goroutine, so the loop stays
// responsive while it runs and can cancel its source fetches.
type syncCycle struct {
	// cancelFetch cancels the cycle's fetch context only: the source syncs
	// and the history backfill stop and the pipelines are skipped, while
	// pipelines already running (they run on the daemon's context) are never
	// cut off.
	cancelFetch context.CancelCauseFunc
	done        chan struct{} // closed once runSync has returned
	// resetTicker makes the next poll a full interval after this cycle ends
	// (the initial, wake and trigger cycles).
	resetTicker bool
	// slept is set when a sleep was detected while the cycle ran (its
	// fetches cancelled, or its pipelines left to finish), restart when a
	// manual trigger cancelled its fetches. Both touched only by the loop
	// goroutine.
	slept   bool
	restart bool
}

// startCycle runs runSync in a goroutine: its pipelines on ctx, its source
// fetches and history backfill on a context derived from ctx that the loop
// can cancel. A daemon shutdown cancels both.
func (d *Daemon) startCycle(ctx context.Context, resetTicker bool) *syncCycle {
	fetchCtx, cancel := context.WithCancelCause(ctx)
	// Set here, on the loop goroutine, so a trigger right after this never
	// reads the previous cycle's state.
	d.setSection(sectionSlackFetch)
	d.markFetchProgress()
	c := &syncCycle{cancelFetch: cancel, done: make(chan struct{}), resetTicker: resetTicker}
	go func() {
		defer close(c.done)
		defer cancel(nil)
		d.runSync(ctx, fetchCtx)
	}()
	return c
}

// monoEpoch is the origin of monoNow's default: its monotonic reading is
// what every stall measurement subtracts from.
var monoEpoch = time.Now()

// monoNow is the loop's monotonic clock as the time since monoEpoch: the
// d.loopMono seam, else time.Since. The monotonic clock stops while a Mac
// sleeps, so a stall measured on it never includes the sleep.
func (d *Daemon) monoNow() time.Duration {
	if d.loopMono != nil {
		return d.loopMono()
	}
	return time.Since(monoEpoch)
}

// markFetchProgress stamps the running cycle's last source-fetch progress:
// a fetch phase boundary in runSync, a Slack sync whose counters moved or
// that Slack answered a call for (startSyncHeartbeat).
func (d *Daemon) markFetchProgress() {
	d.fetchProgressAt.Store(int64(d.monoNow()))
}

// fetchStalledFor is how long (awake time) the running cycle's source fetches
// have made no progress.
func (d *Daemon) fetchStalledFor() time.Duration {
	return d.monoNow() - time.Duration(d.fetchProgressAt.Load())
}

// triggerRestarts reports whether a manual trigger arriving now cancels the
// running cycle c's source fetches and starts a fresh cycle: c is in its
// Slack sync, that sync has made no progress for at least manualRestartAfter,
// and nothing has cancelled the fetches yet.
func (d *Daemon) triggerRestarts(c *syncCycle) bool {
	return !c.slept && !c.restart && d.section() == sectionSlackFetch &&
		d.fetchStalledFor() >= manualRestartAfter
}

// runLoop runs the initial cycle, then one cycle per poll tick, manual trigger
// and (with sync.sync_on_wake) wake, never two at once. It returns once ctx is
// cancelled and the running cycle, if any, has returned.
//
// A cycle's source fetches and history backfill run on their own context,
// which the loop cancels; its pipelines run on ctx and always finish (a
// cancelled fetch skips them instead). A sleep detected while a cycle fetches
// or backfills cancels that work, whatever sync_on_wake says: Go's timeouts
// count awake time only, so a request caught by a sleep can hang for half an
// hour of wall time across Power Nap wakes, and the cycle would then run its
// pipelines on data its failed syncs never refreshed. A sleep detected during
// the pipelines lets them finish and skips the backfill after them. Either
// way the loop drops the pooled connections the sleep may have killed at
// once, waits for the cycle to return, and after wakeSettleDelay starts a
// fresh cycle (sync_on_wake on) or lets the next tick run one (off). A sleep
// while the loop is idle takes the same path minus the cycle. Another sleep
// during the delay starts the delay over.
//
// A trigger during the history backfill is queued: its budget bounds the
// wait.
//
// A manual trigger while a cycle runs cancels its fetches and starts a fresh
// cycle as soon as it returns, without the delay, when triggerRestarts says
// so (the Slack sync stalled); otherwise it is queued (collapsed into one) and
// served right after the cycle. A trigger during the delay is folded into the
// one cycle the delay ends with, sync_on_wake on or off. Ticks are not read
// while a cycle runs or the delay counts down, so they wait (collapsed into
// one) and are served right after.
func (d *Daemon) runLoop(ctx context.Context, pollInterval time.Duration) error {
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	// The initial cycle, right away.
	cycle := d.startCycle(ctx, true)
	var settle *time.Timer // the post-wake delay, nil when not counting down
	triggerQueued := false // a trigger that waits for the running cycle or the delay
	defer func() {
		if settle != nil {
			settle.Stop()
		}
	}()

	for {
		var cycleDone <-chan struct{}
		var settleC <-chan time.Time
		var tickC <-chan time.Time
		switch {
		case cycle != nil:
			cycleDone = cycle.done
		case settle != nil:
			settleC = settle.C
		default:
			tickC = ticker.C
		}

		select {
		case <-ctx.Done():
			// The cycle's contexts derive from ctx: both are already cancelled.
			if cycle != nil {
				<-cycle.done
			}
			d.logger.Println("shutting down")
			return nil
		case <-cycleDone:
			finished := cycle
			cycle = nil
			switch {
			case finished.slept:
				// A restart the sleep overtook still runs, after the delay.
				if finished.restart {
					triggerQueued = true
				}
				d.logger.Printf("cycle ended after a sleep, waiting %s for the network", wakeSettleDelay)
				settle = time.NewTimer(wakeSettleDelay)
			case finished.restart || triggerQueued:
				if finished.restart {
					// A fetch stalled that long most likely sits on a dead socket.
					dropConnections()
				}
				triggerQueued = false
				cycle = d.startCycle(ctx, true)
			case finished.resetTicker:
				ticker.Reset(pollInterval)
			}
		case <-settleC:
			settle = nil
			if d.config.Sync.SyncOnWake || triggerQueued {
				d.logger.Println("syncing after wake")
				triggerQueued = false
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
			d.onSleep(cycle, &settle, slept.Round(time.Second))
		case _, ok := <-d.triggerChannel():
			if !ok {
				d.triggerCh = nil
				continue
			}
			if d.onTrigger(ctx, &cycle, settle != nil) {
				triggerQueued = true
			}
		}
	}
}

// onSleep is runLoop's answer to a detected sleep: it drops the pooled
// connections the sleep may have killed (idle ones only, so it is safe
// mid-cycle) and then cancels the running cycle's fetch context — its source
// fetches or history backfill stop, while pipelines already running finish
// and the backfill after them is skipped — or starts (over) the post-wake
// delay.
func (d *Daemon) onSleep(cycle *syncCycle, settle **time.Timer, sleptFor time.Duration) {
	dropConnections()
	switch {
	case cycle != nil && cycle.slept:
		d.logger.Printf("sleep detected (slept ~%s), the running cycle already ends in a post-wake wait", sleptFor)
	case cycle != nil:
		switch d.section() {
		case sectionPipelines:
			// They run on ctx: the cancel only skips the backfill after them.
			d.logger.Printf("sleep detected (slept ~%s) during the cycle's pipelines, letting them finish", sleptFor)
		case sectionBackfill:
			d.logger.Printf("sleep detected (slept ~%s), cancelling the running cycle's history backfill", sleptFor)
		case sectionSlackFetch, sectionOtherFetch:
			d.logger.Printf("sleep detected (slept ~%s), cancelling the running cycle's source syncs", sleptFor)
		}
		cycle.slept = true
		cycle.cancelFetch(errCycleSlept)
	case *settle != nil:
		d.logger.Printf("sleep detected (slept ~%s), starting the %s post-wake wait over", sleptFor, wakeSettleDelay)
		(*settle).Reset(wakeSettleDelay)
	default:
		d.logger.Printf("sleep detected (slept ~%s), waiting %s for the network", sleptFor, wakeSettleDelay)
		*settle = time.NewTimer(wakeSettleDelay)
	}
}

// onTrigger is runLoop's answer to a manual trigger: it starts a cycle when
// the loop is idle, cancels a running cycle's fetches when its Slack sync
// stalled (the loop starts a fresh cycle once it returns), and otherwise
// reports that the trigger waits for the running cycle or the post-wake
// delay.
func (d *Daemon) onTrigger(ctx context.Context, cycle **syncCycle, settling bool) (queued bool) {
	c := *cycle
	switch {
	case c == nil && settling:
		d.logger.Println("manual sync trigger received during the post-wake wait, syncing after it")
		return true
	case c == nil:
		d.logger.Println("manual sync trigger received, syncing")
		*cycle = d.startCycle(ctx, true)
		return false
	case d.triggerRestarts(c):
		d.logger.Printf("manual sync trigger received after %s without Slack sync progress, cancelling the source syncs and syncing afresh",
			d.fetchStalledFor().Round(time.Second))
		c.restart = true
		c.cancelFetch(errCycleRestart)
		return false
	case d.section() == sectionPipelines:
		d.logger.Println("manual sync trigger received during the cycle's pipelines, syncing after it")
		return true
	case d.section() == sectionBackfill:
		d.logger.Println("manual sync trigger received during the history backfill, syncing after it")
		return true
	default:
		d.logger.Println("manual sync trigger received during the cycle's source syncs, syncing after it")
		return true
	}
}

// dropConnections is dropPooledConnections, a var so tests can count calls.
var dropConnections = dropPooledConnections

// dropPooledConnections closes the idle pooled HTTP connections a sleep may
// have left dead, so the next requests dial afresh: http.DefaultTransport's —
// every integration whose client leaves Transport nil, and the oauth2 clients
// layered on it — and the Slack clients' shared transport.
func dropPooledConnections() {
	if tr, ok := http.DefaultTransport.(*http.Transport); ok {
		tr.CloseIdleConnections()
	}
	slack.CloseIdleConnections()
}
