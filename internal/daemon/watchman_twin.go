package daemon

import (
	"context"
	"time"

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
}

// SetWatchmanTwin wires the twin worker (spec 2026-11-16-watchman-design
// §4) over its own Answerer (its own held-line key; the hub keeps another)
// and start, the session start of a handover the twin continues. Call it
// after SetDB. The decisions run on watchmanTwinGenerator: strong tier for
// watchman.decide, light for the watchman.label park check.
func (d *Daemon) SetWatchmanTwin(a *askanswer.Answerer, start func(ctx context.Context, workbenchID, targetID int64, brief string) error) {
	d.watchmanTwin = watchmanact.NewTwin(watchmanact.TwinDeps{
		DB:       d.db,
		Answerer: a,
		Decide: func(ctx context.Context, it watchman.Item) (watchman.Decision, error) {
			gen, store := d.watchmanTwinGenerator(ctx), prompts.New(d.db, nil)
			return watchmanact.LiveDecide(ctx, d.db, gen, store, watchman.NewLLMLabeler(gen, store), it)
		},
		Parked: func(ctx context.Context, text string) (bool, string, error) {
			labeler := watchman.NewLLMLabeler(d.watchmanTwinGenerator(ctx), prompts.New(d.db, nil))
			return watchmanact.LabelParked(labeler)(ctx, text)
		},
		StartSession: start,
	})
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
// nudge, without waiting for the cycle. The returned stop cancels it and
// waits for the items still deciding (killed instead, their leases expire).
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
		for {
			d.phaseWatchmanTwin(runCtx)
			select {
			case <-runCtx.Done():
				return
			case <-d.watchmanWakeCh:
			case <-d.watchmanTwinCycle:
			}
		}
	}()
	return func() {
		cancel()
		<-done
		d.watchmanTwin.Wait()
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
// then lease what may decide now. Logs carry counts, never text.
func (d *Daemon) phaseWatchmanTwin(ctx context.Context) {
	if ctx.Err() != nil {
		return
	}
	if n, err := d.db.ScanWatchmanWaitPoints(time.Now(), watchman.ItemQuestion); err != nil {
		d.logger.Printf("watchman twin: scanning wait points: %v", err)
	} else if n > 0 {
		d.logger.Printf("watchman twin: queued %d missed wait points", n)
	}
	d.watchmanTwin.DeliverHeld(ctx)
	if n := d.watchmanTwin.RunOnce(ctx); n > 0 {
		d.logger.Printf("watchman twin: deciding %d items", n)
	}
}
