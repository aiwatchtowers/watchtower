package daemon

import (
	"context"
	"errors"
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
	return d.MorningBriefPrimitives()
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

// phaseMorningBrief is the Morning brief slot, where phaseBriefing and the
// day-plan phases ran. With the built-in not active it runs those legacy
// phases unchanged; otherwise the built-in's slot run (brief, then plan, one
// automation run) and then the day plan's conflict phase, which stays Go.
func (d *Daemon) phaseMorningBrief(ctx context.Context, now time.Time) {
	if d.builtins == nil || !d.builtinActive[morningBriefID] {
		d.phaseBriefing(ctx)
		d.runDayPlanPhases(ctx, now)
		return
	}
	d.mbOwner = db.Owner{}
	if d.config.DayPlan.Enabled && d.dayPlanPipeline != nil && d.db != nil {
		d.mbOwner = d.dayPlanOwner(now)
	}
	d.mbNow = now
	defer func() { d.mbNow = time.Time{} }()
	d.builtins.RunSlot(ctx, builtin.SlotMorningBrief)
	d.runDayPlanConflictPhase(ctx, now, d.mbOwner)
}

// builtinNow is the clock of the slot's primitives: the cycle's now while
// phaseMorningBrief runs, else the wall clock.
func (d *Daemon) builtinNow() time.Time {
	if !d.mbNow.IsZero() {
		return d.mbNow
	}
	return time.Now()
}

// briefDue is phaseBriefing's gate.
func (d *Daemon) briefDue(now time.Time) bool {
	return d.config.Briefing.Enabled && d.briefingPipe != nil && d.shouldRunBriefingAt(now) && d.briefingHasOwner(now)
}

// planDue is the day-plan phase's gate over the cycle's owner.
func (d *Daemon) planDue(now time.Time) bool {
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
// pipeline_runs row named briefing, a no-owner benign skip logged once a
// day, a real failure charged to the day's attempt budget, last_briefing.txt
// stamped when today's briefing was made.
func (d *Daemon) trackBrief(date string, run func() (int, error)) (int, error) {
	var id int
	var runErr error
	d.trackedPipelineRun("briefing", func() pipelineRunStats {
		now := d.builtinNow()
		id, runErr = run()
		err := runErr
		if errors.Is(err, db.ErrNoOwner) {
			d.logNoOwnerOnce(now, "briefing")
			err, runErr = nil, nil
		}
		today := now.Format(time.DateOnly)
		if err != nil {
			d.recordBriefingAttempt(today)
			d.logger.Printf("briefing error: %v", err)
		} else if id > 0 {
			d.logger.Printf("generated briefing (id=%d)", id)
			if date == today {
				d.lastBriefing = now
				d.saveLastBriefing()
			}
		}
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
// pipeline_runs row named day_plan, a failure charged to the day's attempt
// budget, today's plan remembered.
func (d *Daemon) trackPlan(date string, run func() (*db.DayPlan, error)) (*db.DayPlan, error) {
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
		if runErr != nil {
			d.recordDayPlanAttempt(today)
			d.logger.Printf("dayplan: generation failed: %v", runErr)
		} else {
			if date == today {
				d.lastDayPlanDate = date
			}
			d.logger.Printf("dayplan: generated plan for %s", date)
		}
		return pipelineRunStats{items: items, inTok: inTok, outTok: outTok, cost: cost, totalAPI: totalAPI, err: runErr}
	})
	return plan, runErr
}

// sweepBuiltinRuns ends the runs a previous daemon left running or waiting
// (the executor's start sweep, AUTO-08): a built-in's run left running would
// otherwise block every later slot run of it. Done before the sync loop and
// the owner-recipe executor start, also when that executor is not wired.
func (d *Daemon) sweepBuiltinRuns() {
	if d.builtins == nil || d.db == nil {
		return
	}
	n, err := d.db.MarkInterruptedAutomationRuns(time.Now())
	switch {
	case err != nil:
		d.logger.Printf("built-ins: ending the runs left by the previous daemon: %v", err)
	case n > 0:
		d.logger.Printf("built-ins: %d run(s) left by the previous daemon ended as interrupted", n)
	}
}
