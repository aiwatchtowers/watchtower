package daemon

import (
	"context"
	"time"

	"watchtower/internal/aiconsent"
	"watchtower/internal/askanswer"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/watchman"
	"watchtower/internal/watchmanact"
)

// WatchmanTwin is the twin worker the daemon drives (watchmanact.Twin).
type WatchmanTwin interface {
	RunOnce(ctx context.Context) int
	Wait()
	DeliverHeld(ctx context.Context)
	// CheckStalls is the stall watch's tick (spec 2026-11-21-watchman-tuning
	// §4b): a stopped handed agent is pinged, at most 3 times, then parked.
	CheckStalls(ctx context.Context)
}

// watchmanStallTick is how often the twin worker checks the armed sessions
// for a stopped agent (the stall watch).
const watchmanStallTick = 60 * time.Second

// SetWatchmanTwin wires the twin worker (spec 2026-11-16-watchman-design
// §4) over its own Answerer (its own held-line key; the hub keeps another)
// and start, the session start of a handover the twin continues. Call it
// after SetDB. The decisions run on watchmanTwinGenerator: strong tier for
// watchman.decide, light for the watchman.label park check. A diff review
// reads the session's review place (LiveReviewPlace) and its PR's base
// through gh (GHPRBase). live reads a session's live run from the same
// session port the Answerer delivers through (the stall watch; nil = off).
func (d *Daemon) SetWatchmanTwin(a *askanswer.Answerer, live func(ctx context.Context, sessionID int64) (askanswer.LiveRun, bool, error),
	start func(ctx context.Context, workbenchID, targetID int64, brief string) error) {
	d.watchmanTwin = watchmanact.NewTwin(watchmanact.TwinDeps{
		DB:       d.db,
		Answerer: a,
		Decide: func(ctx context.Context, it watchman.Item) (watchman.Decision, error) {
			gen, store := d.watchmanTwinGenerator(ctx), prompts.New(d.db, nil)
			return watchmanact.LiveDecide(ctx, d.db, gen, store, watchman.NewLLMLabeler(gen, store), d.logger.Printf, it)
		},
		Parked: func(ctx context.Context, text string) (bool, string, error) {
			labeler := watchman.NewLLMLabeler(d.watchmanTwinGenerator(ctx), prompts.New(d.db, nil))
			return watchmanact.LabelParked(labeler)(ctx, text)
		},
		StartSession: start,
		ReviewPlace:  watchmanact.LiveReviewPlace(d.db),
		PRBase:       watchmanact.GHPRBase(watchmanact.ExecRun),
		Live:         live,
		Wake:         d.wakeWatchmanTwin,
	})
}

// wakeWatchmanTwin asks the twin worker's loop for another pass, as a wait
// point's writer does (non-blocking; a pass already asked for absorbs it):
// the twin calls it when a decision ends and when an item it put back comes
// due, so a queued item never waits for the next cycle.
func (d *Daemon) wakeWatchmanTwin() {
	if ch := d.watchmanWakeCh; ch != nil {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// watchmanTwinGenerator is the Watchman generator outside the cycle's worker
// pool: a twin call queued behind the cycle's pipelines would run past the
// label check's timeout (which parks) or the item's lease. At most
// watchmanact.MaxDeciding items call at once.
func (d *Daemon) watchmanTwinGenerator(ctx context.Context) digest.Generator {
	return digest.WithCallTimeout(watchmanGeneratorFactory(config.RoutingSnapshot(ctx, d.config)), digest.DaemonAICallTimeout)
}

// startWatchmanTwin runs the twin worker beside the sync loop: once at start,
// then on every Watchman wake (a wait point's writer) and every cycle's
// nudge, without waiting for the cycle; and every watchmanStallTick the
// stall watch (CheckStalls) on the same goroutine, so it never overlaps a
// pass's held-line retries. The returned stop cancels it and waits for the
// items still deciding (killed instead, their leases expire).
func (d *Daemon) startWatchmanTwin(ctx context.Context) (stop func()) {
	if d.watchmanTwin == nil || d.db == nil {
		return func() {}
	}
	if d.watchmanWakeCh == nil {
		d.watchmanWakeCh = make(chan struct{}, 1)
	}
	d.watchmanTwinCycle = make(chan struct{}, 1)
	runCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		tick := time.NewTicker(watchmanStallTick)
		defer tick.Stop()
		for {
			d.phaseWatchmanTwin(runCtx)
			if !d.awaitWatchmanTwinPass(runCtx, tick.C) {
				return
			}
		}
	}()
	return func() {
		cancel()
		<-done
		d.watchmanTwin.Wait()
	}
}

// awaitWatchmanTwinPass waits for the next pass's reason — a Watchman wake
// or a cycle's nudge — running the stall watch on each tick meanwhile;
// false once ctx ends.
func (d *Daemon) awaitWatchmanTwinPass(ctx context.Context, tick <-chan time.Time) bool {
	for {
		select {
		case <-ctx.Done():
			return false
		case <-d.watchmanWakeCh:
			return true
		case <-d.watchmanTwinCycle:
			return true
		case <-tick:
			d.watchmanTwin.CheckStalls(ctx)
		}
	}
}

// nudgeWatchmanTwin asks the twin worker for a pass this cycle (no-op when
// the twin is not wired; a pass already asked for absorbs it).
func (d *Daemon) nudgeWatchmanTwin() {
	select {
	case d.watchmanTwinCycle <- struct{}{}:
	default:
	}
}

// phaseWatchmanTwin is one pass of the twin worker: queue the wait points of
// armed sessions no writer queued (spec §7), retry the twin's held lines,
// then lease what may decide now. Each pass binds the current routing (as a
// cycle does), so a routing reload reaches the next decisions. Logs carry
// counts, never text.
func (d *Daemon) phaseWatchmanTwin(ctx context.Context) {
	if ctx.Err() != nil {
		return
	}
	if d.routingJob != nil {
		ctx, _ = d.routingJob(ctx, ctx)
	}
	if n, err := d.db.ScanWatchmanWaitPoints(time.Now(), watchman.ItemQuestion); err != nil {
		d.logger.Printf("watchman twin: scanning wait points: %v", err)
	} else if n > 0 {
		d.logger.Printf("watchman twin: queued %d missed wait points", n)
	}
	d.watchmanTwin.DeliverHeld(ctx)
	// Deciding is background AI (BGAI-01): while it is paused the items stay
	// queued, as in Off or Away, and the next allowed pass takes them. The
	// reader is called directly (not consentNow, whose log state belongs to
	// the cycle goroutine).
	read := d.consent
	if read == nil {
		read = aiconsent.Current
	}
	if !read().Allowed() {
		return
	}
	if n := d.watchmanTwin.RunOnce(aiconsent.WithAdmitted(ctx, "phase:watchman-twin")); n > 0 {
		d.logger.Printf("watchman twin: deciding %d items", n)
	}
}
