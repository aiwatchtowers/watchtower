package builtin

import (
	"context"
	"errors"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/briefing"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
)

type fakeBrief struct {
	calls []string // dates
	opts  []briefing.RunOptions
	id    int
	err   error
	in    int
}

func (f *fakeBrief) RunForDateWith(_ context.Context, date string, opts briefing.RunOptions) (int, error) {
	f.calls = append(f.calls, date)
	f.opts = append(f.opts, opts)
	return f.id, f.err
}
func (f *fakeBrief) AccumulatedUsage() (int, int, float64, int) { return f.in, 7, 0, f.in + 7 }
func (f *fakeBrief) LastPromptNote() string                     { return "brief note" }

type fakePlan struct {
	opts []dayplan.RunOptions
	plan *db.DayPlan
	err  error
}

func (f *fakePlan) Run(_ context.Context, opts dayplan.RunOptions) (*db.DayPlan, error) {
	f.opts = append(f.opts, opts)
	return f.plan, f.err
}
func (f *fakePlan) AccumulatedUsage() (int, int, float64, int) { return 30, 4, 0, 34 }
func (f *fakePlan) LastPromptNote() string                     { return "" }

var mbNow = time.Date(2026, 10, 22, 7, 0, 0, 0, time.Local)

func mbHooks(briefDue, planDue bool) MorningBriefHooks {
	return MorningBriefHooks{
		BriefDue: func(time.Time) bool { return briefDue },
		PlanDue:  func(time.Time) bool { return planDue },
		Owner:    func() (db.Owner, error) { return db.Owner{ID: "U1", SlackUserID: "U1"}, nil },
		Items:    func(int64) (int, error) { return 3, nil },
		Now:      func() time.Time { return mbNow },
	}
}

func call(name, trigger string, in automations.BuiltinInput) automations.PrimitiveCall {
	return automations.PrimitiveCall{Name: name, BuiltinID: mbID, Prompt: "P-" + name,
		Trigger: automations.TriggerInfo{Kind: trigger}, Input: in}
}

func TestMorningBriefPrimitives_SyncGatesSkip(t *testing.T) {
	b, p := &fakeBrief{id: 5}, &fakePlan{}
	prims := MorningBriefPrimitives(b, p, mbHooks(false, false))
	for _, name := range []string{"brief.compose", "plan.compose"} {
		res, err := prims[name](context.Background(), call(name, db.TriggerSync, automations.BuiltinInput{}))
		if err != nil || res.Status != "skipped" {
			t.Fatalf("%s: got %+v, %v; want skipped", name, res, err)
		}
	}
	if len(b.calls) != 0 || len(p.opts) != 0 {
		t.Fatalf("a skipped primitive ran its pipeline: %d, %d", len(b.calls), len(p.opts))
	}
	// A manual run asks no gate.
	res, err := prims["brief.compose"](context.Background(), call("brief.compose", db.TriggerManual, automations.BuiltinInput{}))
	if err != nil || res.Status != "done" || res.Fields["briefing_id"] != 5 {
		t.Fatalf("manual brief: %+v, %v", res, err)
	}
}

func TestMorningBriefPrimitives_OnlySkipsTheOther(t *testing.T) {
	b, p := &fakeBrief{id: 1}, &fakePlan{plan: &db.DayPlan{ID: 9}}
	prims := MorningBriefPrimitives(b, p, mbHooks(true, true))
	in := automations.BuiltinInput{Only: []string{"plan.compose"}}
	res, err := prims["brief.compose"](context.Background(), call("brief.compose", db.TriggerManual, in))
	if err != nil || res.Status != "skipped" || len(b.calls) != 0 {
		t.Fatalf("brief with only=[plan]: %+v, %v, calls %d", res, err, len(b.calls))
	}
	res, err = prims["plan.compose"](context.Background(), call("plan.compose", db.TriggerManual, in))
	if err != nil || res.Status != "done" || res.Fields["plan_id"] != int64(9) || res.Fields["items"] != 3 {
		t.Fatalf("plan: %+v, %v", res, err)
	}
}

func TestMorningBriefPrimitives_PassesPromptDateFeedbackAndUsage(t *testing.T) {
	b, p := &fakeBrief{id: 2, in: 100}, &fakePlan{plan: &db.DayPlan{ID: 3}}
	var tracked []string
	h := mbHooks(true, true)
	h.TrackBrief = func(trigger, date string, run func() (int, error)) (int, error) {
		tracked = append(tracked, "brief:"+trigger+":"+date)
		return run()
	}
	h.TrackPlan = func(trigger, date string, run func() (*db.DayPlan, error)) (*db.DayPlan, error) {
		tracked = append(tracked, "plan:"+trigger+":"+date)
		return run()
	}
	prims := MorningBriefPrimitives(b, p, h)

	res, err := prims["brief.compose"](context.Background(), call("brief.compose", db.TriggerSync, automations.BuiltinInput{}))
	if err != nil {
		t.Fatal(err)
	}
	if b.calls[0] != "2026-10-22" || b.opts[0].Prompt != "P-brief.compose" {
		t.Fatalf("brief got date %q prompt %q", b.calls[0], b.opts[0].Prompt)
	}
	if res.Usage.InputTokens != 100 || res.Usage.OutputTokens != 7 || res.Note != "brief note" {
		t.Fatalf("brief usage/note: %+v", res)
	}

	in := automations.BuiltinInput{Date: "2026-10-20", Feedback: "less meetings"}
	res, err = prims["plan.compose"](context.Background(), call("plan.compose", db.TriggerManual, in))
	if err != nil {
		t.Fatal(err)
	}
	o := p.opts[0]
	if o.Date != "2026-10-20" || o.UserID != "U1" || o.Feedback != "less meetings" || !o.Force || o.Prompt != "P-plan.compose" {
		t.Fatalf("plan options: %+v", o)
	}
	if res.Usage.InputTokens != 30 || res.Usage.OutputTokens != 4 {
		t.Fatalf("plan usage: %+v", res.Usage)
	}
	if len(tracked) != 2 || tracked[0] != "brief:sync:2026-10-22" || tracked[1] != "plan:manual:2026-10-20" {
		t.Fatalf("tracked: %v", tracked)
	}
}

func TestMorningBriefPrimitives_ErrorsKeepUsage(t *testing.T) {
	boom := errors.New("boom")
	b, p := &fakeBrief{err: boom, in: 11}, &fakePlan{err: boom}
	prims := MorningBriefPrimitives(b, p, mbHooks(true, true))
	res, err := prims["brief.compose"](context.Background(), call("brief.compose", db.TriggerSync, automations.BuiltinInput{}))
	if !errors.Is(err, boom) || res.Usage.InputTokens != 11 {
		t.Fatalf("brief error: %+v, %v", res, err)
	}
	res, err = prims["plan.compose"](context.Background(), call("plan.compose", db.TriggerSync, automations.BuiltinInput{}))
	if !errors.Is(err, boom) || res.Usage.InputTokens != 30 {
		t.Fatalf("plan error: %+v, %v", res, err)
	}
}

func TestMorningBriefPrimitives_PlanWithoutOwnerIsErrNoOwner(t *testing.T) {
	p := &fakePlan{}
	h := mbHooks(true, true)
	h.Owner = func() (db.Owner, error) { return db.Owner{}, nil }
	prims := MorningBriefPrimitives(&fakeBrief{}, p, h)
	_, err := prims["plan.compose"](context.Background(), call("plan.compose", db.TriggerManual, automations.BuiltinInput{}))
	if !errors.Is(err, db.ErrNoOwner) || len(p.opts) != 0 {
		t.Fatalf("got %v, runs %d; want ErrNoOwner and no run", err, len(p.opts))
	}
}
