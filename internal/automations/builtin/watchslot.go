package builtin

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/watch"
	"watchtower/internal/customtracks"
	"watchtower/internal/db"
)

// SkippedNoOwner is why a watch recipe did not run when no owner identity is connected: its track
// cannot be made (OWNER-02), and nothing is written.
const SkippedNoOwner = "no_owner"

// watchLookback is how far back a never-scanned watch track's activity probe
// looks: the custom-track scan's own first-scan lookback.
const watchLookback = 7 * 24 * time.Hour

// watermarkLayout is the custom-track scan's watermark format (tracks.last_run_at).
const watermarkLayout = "2006-01-02T15:04:05Z"

// WatchScanner is the custom-track scan as track.scan and the watch slot
// call it (*customtracks.Pipeline).
type WatchScanner interface {
	ScanBound(ctx context.Context, t db.Track, o customtracks.ScanOptions) ([]db.TrackEvent, error)
	Due(t db.Track, now time.Time) bool
	RecordFailure(trackID int, now time.Time, err error)
	// AccumulatedUsage is the input tokens, output tokens, cost and model
	// calls of every scan so far; it only grows.
	AccumulatedUsage() (int, int, float64, int)
}

// WatchPrimitives returns track.scan over d and s: it ensures the run's
// recipe has its bound track (owned by owner(), named after the recipe, with
// the call's instruction), mirrors the instruction onto it, and scans it
// with the run's Since (Run Now's Scan from) and the call's extra items. No
// owner, or a dismissed track, gives {status: "skipped"} and scans nothing;
// a sync run of a track that is not due (paused, or today's failure budget
// spent) is skipped too, and a sync run's failed scan is charged to the
// budget (both on now's UTC day; nil now = time.Now). A done call returns
// {events: <how many the scan added>}. The call reports the tokens its scan
// spent (s.AccumulatedUsage before and after, a failed scan's too), so they
// land on the run and its token budget applies; the scans of one scanner
// must not overlap (the slot runs its recipes one after another).
func WatchPrimitives(d *db.DB, s WatchScanner, owner func() (db.Owner, error), now func() time.Time) map[string]automations.PrimitiveFunc {
	if now == nil {
		now = time.Now
	}
	return map[string]automations.PrimitiveFunc{
		"track.scan": func(ctx context.Context, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			if d == nil || s == nil || owner == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			return trackScan(ctx, d, s, owner, now(), call)
		},
	}
}

func trackScan(ctx context.Context, d *db.DB, s WatchScanner, owner func() (db.Owner, error), now time.Time, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
	skipped := func(note string) (automations.PrimitiveResult, error) {
		return automations.PrimitiveResult{Status: "skipped", Note: note}, nil
	}
	run, err := d.GetAutomationRun(call.Trigger.RunID)
	if err != nil {
		return automations.PrimitiveResult{}, fmt.Errorf("track.scan: reading the run: %w", err)
	}
	a, err := d.GetAutomation(run.AutomationID)
	if err != nil {
		return automations.PrimitiveResult{}, fmt.Errorf("track.scan: reading the recipe: %w", err)
	}
	o, err := owner()
	if err != nil {
		return automations.PrimitiveResult{}, fmt.Errorf("track.scan: resolving the owner: %w", err)
	}
	if !o.Known() {
		return skipped(db.ErrNoOwner.Error())
	}
	id, err := d.EnsureWatchTrack(a.ID, o.ID, a.Name, call.Prompt)
	if err != nil {
		return automations.PrimitiveResult{}, fmt.Errorf("track.scan: %w", err)
	}
	if err := d.SetWatchInstruction(id, call.Prompt); err != nil {
		return automations.PrimitiveResult{}, fmt.Errorf("track.scan: %w", err)
	}
	t, err := d.GetTrackByID(id)
	if err != nil {
		return automations.PrimitiveResult{}, fmt.Errorf("track.scan: reading track %d: %w", id, err)
	}
	if t.DismissedAt != "" {
		return skipped("the track is dismissed")
	}
	sync := call.Trigger.Kind == db.TriggerSync
	if sync && !s.Due(*t, now) {
		return skipped("the track is paused or spent today's scan budget")
	}
	in0, out0, _, _ := s.AccumulatedUsage()
	events, err := s.ScanBound(ctx, *t, customtracks.ScanOptions{
		Instruction: call.Prompt, Since: call.Input.Since, Extra: extraItems(call.Args["extra"]),
	})
	in1, out1, _, _ := s.AccumulatedUsage()
	// The pipeline reports no cost: the meter prices the tokens (usageOf).
	usage := usageOf(in1-in0, out1-out0, 0, 0)
	if err != nil {
		if sync {
			s.RecordFailure(t.ID, now, err)
		}
		return automations.PrimitiveResult{Usage: usage}, err
	}
	return automations.PrimitiveResult{Status: "done", Fields: map[string]any{"events": len(events)}, Usage: usage}, nil
}

// extraItems maps track.scan's checked extra argument onto the scan's
// items; an item whose at does not parse (the SDK checked it) is dropped.
func extraItems(v any) []customtracks.ExtraItem {
	items, _ := v.([]automations.TrackScanItem)
	out := make([]customtracks.ExtraItem, 0, len(items))
	for _, it := range items {
		at, err := time.Parse(time.RFC3339, it.At)
		if err != nil {
			continue
		}
		out = append(out, customtracks.ExtraItem{SourceType: it.SourceType, SourceID: it.SourceID, Text: it.Text, At: at})
	}
	return out
}

// WatchGate decides, before any run row exists, whether a watch recipe's
// sync run is due now.
type WatchGate interface {
	Due(ctx context.Context, a db.Automation, t db.Track, now time.Time) bool
}

// NewWatchGate is the watch slot's gate: track t is due (s.Due: enabled, not
// dismissed, under today's failure budget) and there is activity since its
// watermark (a never-scanned track: the last 7 days) up to the last whole
// second — the window the scan itself reads. A failed probe is logged to
// logger (the runner's; nil = log.Default()) and reads as not due.
func NewWatchGate(d *db.DB, s WatchScanner, logger *log.Logger) WatchGate {
	if logger == nil {
		logger = log.Default()
	}
	return watchGate{d: d, s: s, logger: logger}
}

type watchGate struct {
	d      *db.DB
	s      WatchScanner
	logger *log.Logger
}

func (g watchGate) Due(_ context.Context, a db.Automation, t db.Track, now time.Time) bool {
	if !g.s.Due(t, now) {
		return false
	}
	since := t.LastRunAt
	if since == "" {
		since = now.Add(-watchLookback).UTC().Format(watermarkLayout)
	}
	has, err := g.d.HasScanActivity(since, now.UTC().Add(-time.Second).Format(watermarkLayout))
	if err != nil {
		g.logger.Printf("watch recipe %d (%s): %v; not scanned this cycle", a.ID, a.Slug, err)
		return false
	}
	return has
}

// RunWatchSlot runs the watch recipes at the custom_tracks slot, one after
// another in id order; one's failure never stops the next. First the tracks
// of recipes whose file is gone are unbound and paused (their events kept).
// Then, per recipe: an unconfirmed one has its queued manual runs cancelled
// not_runnable and is skipped, as is a disabled one; otherwise its track is
// ensured (no owner: skipped), a queued manual run (Run Now, Scan from) is
// executed without asking the gate, and with none only a due recipe gets a
// sync run row, executed inline.
func (r *Runner) RunWatchSlot(ctx context.Context, g WatchGate) []SlotOutcome {
	if n, err := r.db.UnbindRemovedWatchTracks(); err != nil {
		r.logger.Printf("watch recipes: %v", err)
	} else if n > 0 {
		r.logger.Printf("watch recipes: %d track(s) of removed recipes unbound and paused", n)
	}
	recipes, err := r.db.ListSlotRecipes(string(SlotCustomTracks))
	if err != nil {
		r.logger.Printf("watch recipes: %v", err)
		return nil
	}
	r.endStaleRuns()
	var out []SlotOutcome
	for _, a := range recipes {
		if ctx.Err() != nil {
			break
		}
		out = append(out, r.runWatch(ctx, g, a))
	}
	return out
}

func (r *Runner) runWatch(ctx context.Context, g WatchGate, a db.Automation) SlotOutcome {
	o := SlotOutcome{AutomationID: a.ID}
	fail := func(what string, err error) SlotOutcome {
		r.logger.Printf("%s: %s: %v", o.label(), what, err)
		o.Status = StatusError
		return o
	}
	skip := func(why string) SlotOutcome {
		if err := r.cancelQueuedOf(a.ID); err != nil {
			return fail("cancelling its queued runs", err)
		}
		o.Skipped = why
		return o
	}
	if !a.Confirmed() {
		return skip(SkippedNotConfirmed)
	}
	if !a.Enabled {
		return skip(SkippedOff)
	}
	owner, err := r.db.ResolveOwner()
	if err != nil {
		return fail("resolving the owner", err)
	}
	if !owner.Known() {
		o.Skipped = SkippedNoOwner
		return o
	}
	instruction, _ := watch.Instruction([]byte(a.RecipeText))
	trackID, err := r.db.EnsureWatchTrack(a.ID, owner.ID, a.Name, instruction)
	if err != nil {
		return fail("ensuring its track", err)
	}
	queued, err := r.db.TakeQueuedBuiltinRun(a.ID)
	if err != nil {
		return fail("reading its queued run", err)
	}
	if queued != nil {
		return r.execute(ctx, o, queued.ID, false)
	}
	t, err := r.db.GetTrackByID(trackID)
	if err != nil {
		return fail("reading its track", err)
	}
	now := r.clock.Now()
	if g == nil || !g.Due(ctx, a, *t, now) {
		o.Skipped = SkippedNotDue
		return o
	}
	runID, _, err := r.db.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerSync, Now: now})
	if err != nil {
		return fail("queueing its sync run", err)
	}
	return r.execute(ctx, o, runID, true)
}

// cancelQueuedOf cancels the queued manual runs of automation id as
// not_runnable, as the executor would, logging how many.
func (r *Runner) cancelQueuedOf(id int64) error {
	n := 0
	for {
		run, err := r.db.TakeQueuedBuiltinRun(id)
		if err != nil || run == nil {
			if n > 0 {
				r.logger.Printf("watch recipe %d: %d queued run(s) cancelled: it cannot run now", id, n)
			}
			return err
		}
		switch err := r.db.CancelQueuedNotRunnable(run.ID, r.clock.Now()); {
		case err == nil:
			n++
		case !errors.Is(err, db.ErrRunNotQueued): // claimed meanwhile: not ours to cancel
			return err
		}
	}
}
