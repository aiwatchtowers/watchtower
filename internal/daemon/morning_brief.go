package daemon

import (
	"context"
	"errors"
	"maps"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/db"
)

// morningBriefID is the Morning brief built-in's id.
const morningBriefID = "morning-brief"

// SetBuiltins wires the built-ins' slot runner. active[id] false (or absent)
// keeps that built-in's producers on their legacy phases (the upgrade step
// decides, Task 8).
func (d *Daemon) SetBuiltins(r *builtin.Runner, active map[string]bool) {
	d.builtins = r
	d.builtinActive = active
}

// BuiltinPrimitives is the one map the slot executor gets: the union of
// every built-in's primitives.
func (d *Daemon) BuiltinPrimitives() map[string]automations.PrimitiveFunc {
	out := d.MorningBriefPrimitives()
	for _, m := range []map[string]automations.PrimitiveFunc{
		d.TrackMyThreadsPrimitives(), d.IdeaFinderPrimitives(), d.ReactionPrimitives(), d.WatchPrimitives(),
	} {
		maps.Copy(out, m)
	}
	return out
}

// MorningBriefPrimitives are brief.compose and plan.compose over the
// daemon's briefing and day-plan pipelines, gated and tracked as the legacy
// phases were: the hour gates, attempt budgets, stamps and pipeline_runs
// rows named briefing and day_plan.
func (d *Daemon) MorningBriefPrimitives() map[string]automations.PrimitiveFunc {
	var brief builtin.BriefRunner
	if d.briefingPipe != nil {
		brief = d.briefingPipe
	}
	var plan builtin.PlanRunner
	if d.dayPlanPipeline != nil {
		plan = d.dayPlanPipeline
	}
	return builtin.MorningBriefPrimitives(brief, plan, builtin.MorningBriefHooks{
		BriefDue:   d.briefDue,
		PlanDue:    d.planDue,
		TrackBrief: d.trackBrief,
		TrackPlan:  d.trackPlan,
		Owner:      d.planOwner,
		Items:      d.planItems,
		Now:        d.builtinNow,
	})
}

// MorningBriefGate is the Morning brief's sync gate: due when the brief or
// the plan is.
func (d *Daemon) MorningBriefGate() builtin.Gate { return morningBriefGate{d: d} }

type morningBriefGate struct{ d *Daemon }

func (g morningBriefGate) Due(_ context.Context, _ builtin.Entry, now time.Time) bool {
	return g.d.briefDue(now) || g.d.planDue(now)
}

// briefingNoDataBackoff is how long a sync brief that found no data keeps
// the brief from being due again the same day: without it every cycle of an
// install with nothing to summarize would write one empty run. Before the
// first briefing ever (briefingFresh) the gate asks the pipeline's no-data
// rule instead (briefing.HasMaterial, a read with no model call): nothing to
// summarize is not due and writes no run; data is due at once, so the first
// brief comes in the first cycle after the first digests land.
const briefingNoDataBackoff = time.Hour

// phaseMorningBrief is the Morning brief slot, where phaseBriefing and the
// day-plan phases ran. With the built-in not active it runs those legacy
// phases unchanged — and cancels the built-in's queued Run Now, which only
// the slot runner would take; otherwise the built-in's slot run (brief, then
// plan, one automation run) and then the day plan's conflict phase, which
// stays Go.
func (d *Daemon) phaseMorningBrief(ctx context.Context, now time.Time) {
	if !d.builtinOn(morningBriefID) {
		d.cancelQueuedBuiltinRuns(morningBriefID, now)
		d.phaseBriefingAt(ctx, now)
		d.runDayPlanPhases(ctx, now)
		return
	}
	d.ensureBuiltinsSwept() // the start's sweep failed: retried before the slot
	owner := db.Owner{}
	if d.config.DayPlan.Enabled && d.dayPlanPipeline != nil && d.db != nil {
		owner = d.dayPlanOwner(now)
	}
	d.mbMu.Lock()
	d.mbOwner, d.mbNow = owner, now
	d.mbMu.Unlock()
	defer func() {
		d.mbMu.Lock()
		d.mbNow = time.Time{}
		d.mbMu.Unlock()
	}()
	d.builtins.RunSlot(ctx, builtin.SlotMorningBrief)
	d.runDayPlanConflictPhase(ctx, now, owner)
}

// cancelQueuedBuiltinRuns cancels built-in id's queued manual runs while it
// is on its legacy phases (a Run Now queued before the move failed, or by a
// CLI of this version against an older daemon): nothing would ever take
// them. A failure is logged.
func (d *Daemon) cancelQueuedBuiltinRuns(id string, now time.Time) {
	if d.db == nil {
		return
	}
	n, err := d.db.CancelQueuedBuiltinRuns(id, now)
	switch {
	case err != nil:
		d.logger.Printf("built-in %s: cancelling its queued runs: %v", id, err)
	case n > 0:
		d.logger.Printf("built-in %s: %d queued run(s) cancelled: it runs on its legacy phases", id, n)
	}
}

// builtinNow is the clock of the slot's primitives: the cycle's now while
// phaseMorningBrief runs, else the wall clock.
func (d *Daemon) builtinNow() time.Time {
	d.mbMu.Lock()
	defer d.mbMu.Unlock()
	if !d.mbNow.IsZero() {
		return d.mbNow
	}
	return time.Now()
}

// briefDue is phaseBriefing's gate, plus the no-data rule: before the first
// briefing the pipeline's HasMaterial, after it the no-data backoff.
func (d *Daemon) briefDue(now time.Time) bool {
	d.mbMu.Lock()
	defer d.mbMu.Unlock()
	if !d.config.Briefing.Enabled || d.briefingPipe == nil || !d.shouldRunBriefingAt(now) || !d.briefingHasOwner(now) {
		return false
	}
	if d.briefingFresh() {
		return d.briefingHasMaterial(now)
	}
	return d.briefNoDataAt.IsZero() || !sameCalendarDay(d.briefNoDataAt, now) || now.Sub(d.briefNoDataAt) >= briefingNoDataBackoff
}

// briefingHasMaterial is the pipeline's no-data rule for now's date. A read
// failure is logged and counts as material: the run then decides itself.
func (d *Daemon) briefingHasMaterial(now time.Time) bool {
	has, err := d.briefingPipe.HasMaterial(now.Format(time.DateOnly))
	if err != nil {
		d.logger.Printf("briefing: checking for anything to summarize: %v", err)
		return true
	}
	return has
}

// planDue is the day-plan phase's gate over the cycle's owner.
func (d *Daemon) planDue(now time.Time) bool {
	d.mbMu.Lock()
	defer d.mbMu.Unlock()
	return d.config.DayPlan.Enabled && d.shouldRunDayPlan(now, d.mbOwner)
}

// planOwner is the owner a plan is made for (dayplan.Run adopts the
// owner's earlier rows itself).
func (d *Daemon) planOwner() (db.Owner, error) {
	if d.db == nil {
		return db.Owner{}, errors.New("no database")
	}
	return d.db.ResolveOwner()
}

func (d *Daemon) planItems(planID int64) (int, error) {
	if d.db == nil {
		return 0, nil
	}
	items, err := d.db.GetDayPlanItems(planID)
	return len(items), err
}

// trackBrief is phaseBriefing's tracked run around one brief.compose: a
// pipeline_runs row named briefing and last_briefing.txt stamped when today's
// briefing was made. A sync run's no-owner result is the benign skip (logged
// once a day), its real failure is charged to the day's attempt budget and
// its no-data result starts the no-data backoff. A manual run is the owner's
// own: it charges no attempt and surfaces no owner as db.ErrNoOwner
// (OWNER-02).
func (d *Daemon) trackBrief(trigger, date string, run func() (int, error)) (int, error) {
	sync := trigger == db.TriggerSync
	var id int
	var runErr error
	d.trackedPipelineRun("briefing", func() pipelineRunStats {
		now := d.builtinNow()
		id, runErr = run()
		err := runErr
		today := now.Format(time.DateOnly)
		d.mbMu.Lock()
		switch {
		case sync && errors.Is(err, db.ErrNoOwner):
			d.logNoOwnerOnce(now, "briefing")
			err, runErr = nil, nil
		case err != nil:
			if sync {
				d.recordBriefingAttempt(today)
			}
			d.logger.Printf("briefing error: %v", err)
		case id > 0:
			d.logger.Printf("generated briefing (id=%d)", id)
			if date == today {
				d.lastBriefing = now
				d.saveLastBriefing()
			}
		case sync:
			d.briefNoDataAt = now
		}
		d.mbMu.Unlock()
		items := 0
		if id > 0 {
			items = 1
		}
		inTok, outTok, cost, totalAPI := d.briefingPipe.AccumulatedUsage()
		return pipelineRunStats{items: items, inTok: inTok, outTok: outTok, cost: cost, totalAPI: totalAPI, err: err}
	})
	return id, runErr
}

// trackPlan is runDayPlanPhase's tracked run around one plan.compose: a
// pipeline_runs row named day_plan and today's plan remembered; a sync run's
// failure is charged to the day's attempt budget, a manual run's is not.
func (d *Daemon) trackPlan(trigger, date string, run func() (*db.DayPlan, error)) (*db.DayPlan, error) {
	var plan *db.DayPlan
	var runErr error
	d.trackedPipelineRun("day_plan", func() pipelineRunStats {
		today := d.builtinNow().Format(time.DateOnly)
		plan, runErr = run()
		items := 0
		if plan != nil {
			items = 1
		}
		inTok, outTok, cost, totalAPI := d.dayPlanPipeline.AccumulatedUsage()
		d.mbMu.Lock()
		if runErr != nil {
			if trigger == db.TriggerSync {
				d.recordDayPlanAttempt(today)
			}
			d.logger.Printf("dayplan: generation failed: %v", runErr)
		} else {
			if date == today {
				d.lastDayPlanDate = date
			}
			d.logger.Printf("dayplan: generated plan for %s", date)
		}
		d.mbMu.Unlock()
		return pipelineRunStats{items: items, inTok: inTok, outTok: outTok, cost: cost, totalAPI: totalAPI, err: runErr}
	})
	return plan, runErr
}

// sweepBuiltinRuns ends the built-in runs a previous daemon (or a CLI that
// died) left running or waiting: one left running would block every later
// slot run of its built-in. It runs at the daemon's start, before the sync
// loop and the owner-recipe executor (whose own start sweep leaves the
// built-ins' runs alone, so it can never end a live slot run), and — until it
// has succeeded — again before each Morning brief slot.
func (d *Daemon) sweepBuiltinRuns() {
	if d.builtins == nil || d.db == nil {
		return
	}
	n, err := d.db.MarkInterruptedBuiltinRuns(time.Now())
	switch {
	case err != nil:
		d.logger.Printf("built-ins: ending the runs left by the previous daemon: %v (retried before the next slot)", err)
		return
	case n > 0:
		d.logger.Printf("built-ins: %d run(s) left by the previous daemon ended as interrupted", n)
	}
	d.builtinsSwept = true
}
