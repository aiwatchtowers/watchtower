package builtin

import (
	"context"
	"errors"
	"slices"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/briefing"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
)

// BriefRunner is the briefing pipeline as brief.compose calls it
// (*briefing.Pipeline).
type BriefRunner interface {
	RunForDateWith(ctx context.Context, date string, opts briefing.RunOptions) (int, error)
	AccumulatedUsage() (int, int, float64, int)
	LastPromptNote() string
}

// PlanRunner is the day-plan pipeline as plan.compose calls it
// (*dayplan.Pipeline).
type PlanRunner interface {
	Run(ctx context.Context, opts dayplan.RunOptions) (*db.DayPlan, error)
	AccumulatedUsage() (int, int, float64, int)
	LastPromptNote() string
}

// MorningBriefHooks is what the Morning brief primitives take from their
// caller: the daemon's gates and run tracking, or the CLI's direct calls.
type MorningBriefHooks struct {
	// BriefDue/PlanDue are the sync-run gates (nil = always due: the CLI).
	BriefDue, PlanDue func(now time.Time) bool
	// Track wraps one real attempt (daemon: trackedPipelineRun + attempt
	// budget + stamps; CLI: direct). trigger is the run's (db.TriggerSync,
	// db.TriggerManual, …): only a sync run's attempt is the daemon's
	// schedule's. nil = run directly.
	TrackBrief func(trigger, date string, run func() (int, error)) (int, error)
	TrackPlan  func(trigger, date string, run func() (*db.DayPlan, error)) (*db.DayPlan, error)
	// Owner is the owner a plan is made for.
	Owner func() (db.Owner, error)
	// Items counts a plan's items (the result's items field); nil = 0.
	Items func(planID int64) (int, error)
	// Now is the clock (nil = time.Now).
	Now func() time.Time
}

// errNotWired is a primitive whose pipeline the caller did not wire.
var errNotWired = errors.New("the pipeline is not available")

// MorningBriefPrimitives returns brief.compose and plan.compose over brief
// and plan. Each reports the usage of the pipeline run it made (the
// pipelines reset their usage at the start of every run, so the value read
// after the call is that call's). In a sync run a primitive whose gate says
// not now returns {status: "skipped"}, as does one the run's input.only
// leaves out.
func MorningBriefPrimitives(brief BriefRunner, plan PlanRunner, h MorningBriefHooks) map[string]automations.PrimitiveFunc {
	now := h.Now
	if now == nil {
		now = time.Now
	}
	return map[string]automations.PrimitiveFunc{
		"brief.compose": func(ctx context.Context, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			t := now()
			if skip(call, h.BriefDue, t) {
				return skipped(), nil
			}
			if brief == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			date := runDate(call, t)
			run := func() (int, error) {
				return brief.RunForDateWith(ctx, date, briefing.RunOptions{Prompt: call.Prompt})
			}
			var id int
			var err error
			if h.TrackBrief != nil {
				id, err = h.TrackBrief(call.Trigger.Kind, date, run)
			} else {
				id, err = run()
			}
			res := automations.PrimitiveResult{Status: "done", Fields: map[string]any{"briefing_id": id},
				Note: brief.LastPromptNote(), Usage: usageOf(brief.AccumulatedUsage())}
			return res, err
		},
		"plan.compose": func(ctx context.Context, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			t := now()
			if skip(call, h.PlanDue, t) {
				return skipped(), nil
			}
			if plan == nil || h.Owner == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			owner, err := h.Owner()
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			if !owner.Known() {
				return automations.PrimitiveResult{}, db.ErrNoOwner
			}
			date := runDate(call, t)
			opts := dayplan.RunOptions{UserID: owner.ID, Owner: owner, Date: date, Prompt: call.Prompt,
				Feedback: call.Input.Feedback, Force: call.Input.Force || call.Input.Feedback != ""}
			run := func() (*db.DayPlan, error) { return plan.Run(ctx, opts) }
			var p *db.DayPlan
			if h.TrackPlan != nil {
				p, err = h.TrackPlan(call.Trigger.Kind, date, run)
			} else {
				p, err = run()
			}
			res := automations.PrimitiveResult{Status: "done", Note: plan.LastPromptNote(),
				Usage: usageOf(plan.AccumulatedUsage())}
			if err != nil {
				return res, err
			}
			var planID int64
			items := 0
			if p != nil {
				planID = p.ID
				if h.Items != nil {
					if items, err = h.Items(p.ID); err != nil {
						return res, err
					}
				}
			}
			res.Fields = map[string]any{"plan_id": planID, "items": items}
			return res, nil
		},
	}
}

// skip reports a call that does not run: one the run's input.only leaves
// out, or, in a sync run, one whose gate says not now.
func skip(call automations.PrimitiveCall, due func(time.Time) bool, now time.Time) bool {
	if len(call.Input.Only) > 0 && !slices.Contains(call.Input.Only, call.Name) {
		return true
	}
	return call.Trigger.Kind == db.TriggerSync && due != nil && !due(now)
}

func skipped() automations.PrimitiveResult {
	return automations.PrimitiveResult{Status: "skipped"}
}

// runDate is the call's input date, else now's local date.
func runDate(call automations.PrimitiveCall, now time.Time) string {
	if call.Input.Date != "" {
		return call.Input.Date
	}
	return now.In(time.Local).Format(time.DateOnly)
}

// usageOf is a pipeline's AccumulatedUsage as a PrimitiveUsage; the
// pipelines report no cost, so the meter prices the tokens.
func usageOf(in, out int, _ float64, _ int) automations.PrimitiveUsage {
	return automations.PrimitiveUsage{InputTokens: in, OutputTokens: out}
}
