package builtin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

func (f *fixture) enqueueManual(t *testing.T, eventJSON string) (int64, bool) {
	t.Helper()
	id, coalesced, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: f.row(t).ID, Trigger: db.TriggerManual,
		EventJSON: eventJSON, Now: f.clock.Now()})
	if err != nil {
		t.Fatal(err)
	}
	return id, coalesced
}

func TestRunner_OffWritesNothing(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.cfg.Briefing.Enabled, f.cfg.DayPlan.Enabled = false, false
	if o := f.slotOnce(t); o.Skipped != SkippedOff || o.RunID != 0 {
		t.Errorf("slot = %+v, want off", o)
	}
	if n := len(f.runs(t)); n != 0 || f.gate.count() != 0 || len(f.brief.snapshot()) != 0 {
		t.Errorf("off: %d runs, %d gate calls, %d brief calls", n, f.gate.count(), len(f.brief.snapshot()))
	}
}

func TestRunner_NotDueWritesNoRun(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.gate.due = false
	if o := f.slotOnce(t); o.Skipped != SkippedNotDue {
		t.Errorf("slot = %+v, want not_due", o)
	}
	if n := len(f.runs(t)); n != 0 || f.gate.count() != 1 {
		t.Errorf("not due: %d runs, %d gate calls", n, f.gate.count())
	}
}

func TestRunner_DueWritesOneSyncRun(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	o := f.slotOnce(t)
	runs := f.runs(t)
	if len(runs) != 1 || runs[0].Trigger != db.TriggerSync || runs[0].Status != db.RunSucceeded {
		t.Fatalf("runs = %+v", runs)
	}
	if o.RunID != runs[0].ID || o.Status != db.RunSucceeded || o.Skipped != "" {
		t.Errorf("outcome = %+v", o)
	}
	e := mustEntry(t)
	for name, p := range map[string]*fakePrimitive{"brief": f.brief, "plan": f.plan} {
		calls := p.snapshot()
		want, _ := e.DefaultPrompt(name, "")
		if len(calls) != 1 || calls[0].Prompt != want || calls[0].Trigger.Kind != db.TriggerSync || calls[0].BuiltinID != mbID {
			t.Errorf("%s calls = %d (prompt shipped %v)", name, len(calls), len(calls) == 1 && calls[0].Prompt == want)
		}
	}
}

func TestRunner_BriefFailsPlanStillRuns(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.brief.err = errors.New("model down")
	if o := f.slotOnce(t); o.Status != db.RunFailed {
		t.Errorf("slot = %+v, want failed", o)
	}
	run := f.runs(t)[0]
	if run.ErrorKind != db.ErrKindBackend || !strings.Contains(run.Error, "model down") {
		t.Errorf("run = %s/%s %q", run.Status, run.ErrorKind, run.Error)
	}
	if len(f.plan.snapshot()) != 1 {
		t.Error("the plan did not run after the brief failed")
	}
}

func TestRunner_QueuedManualRunsAtSlotWithoutGate(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.gate.due = false
	id, _ := f.enqueueManual(t, `{"builtin":{"only":["brief.compose"],"date":"2026-10-21"}}`)
	o := f.slotOnce(t)
	if o.RunID != id || o.Status != db.RunSucceeded || f.gate.count() != 0 {
		t.Errorf("slot = %+v, gate calls %d; want the queued run, no gate", o, f.gate.count())
	}
	calls := f.brief.snapshot()
	if len(calls) != 1 || !slices.Equal(calls[0].Input.Only, []string{"brief.compose"}) || calls[0].Input.Date != "2026-10-21" ||
		calls[0].Trigger.Kind != db.TriggerManual {
		t.Errorf("brief calls = %+v", calls)
	}
	if n := len(f.runs(t)); n != 1 {
		t.Errorf("%d runs, want the manual one only", n)
	}
}

func TestRunner_RunNowTwiceCoalesces(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	first, c1 := f.enqueueManual(t, "")
	second, c2 := f.enqueueManual(t, "")
	if first != second || c1 || !c2 {
		t.Fatalf("enqueue = %d/%v then %d/%v, want the second coalesced", first, c1, second, c2)
	}
	if o := f.slotOnce(t); o.RunID != first || o.Status != db.RunSucceeded {
		t.Errorf("slot = %+v", o)
	}
	if n := len(f.runs(t)); n != 1 || len(f.brief.snapshot()) != 1 {
		t.Errorf("%d runs, %d briefs; want one", n, len(f.brief.snapshot()))
	}
}

func TestRunner_UnconfirmedCancelsQueuedManual(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	id, _ := f.enqueueManual(t, "")
	f.writeCopy(t, editedCopy(t, mustEntry(t), "Unconfirmed prompt for %s on %s."))
	f.sync(t)
	if o := f.slotOnce(t); o.Skipped != SkippedNotConfirmed {
		t.Errorf("slot = %+v, want not_confirmed", o)
	}
	run, err := f.d.GetAutomationRun(id)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != db.RunCancelled || run.ErrorKind != db.ErrKindNotRunnable {
		t.Errorf("queued run = %s/%s, want cancelled/not_runnable", run.Status, run.ErrorKind)
	}
	if n := len(f.runs(t)); n != 1 || f.gate.count() != 0 || len(f.brief.snapshot()) != 0 {
		t.Errorf("%d runs, %d gate calls, %d briefs", n, f.gate.count(), len(f.brief.snapshot()))
	}
}

func TestRunner_RunNowIgnoresEnabled(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.cfg.Briefing.Enabled, f.cfg.DayPlan.Enabled = false, false
	f.sync(t)
	if f.row(t).Enabled {
		t.Fatal("the built-in is still on")
	}
	in := automations.BuiltinInput{Only: []string{"plan.compose"}, Feedback: "less meetings", Force: true}
	run, err := f.runner.RunNow(context.Background(), mbID, in)
	if err != nil || run.Status != db.RunSucceeded || run.Trigger != db.TriggerManual {
		t.Fatalf("RunNow = %+v, %v", run, err)
	}
	var payload struct {
		Builtin automations.BuiltinInput `json:"builtin"`
	}
	if err := json.Unmarshal([]byte(run.EventJSON), &payload); err != nil || payload.Builtin.Feedback != "less meetings" {
		t.Errorf("event_json = %q (%v)", run.EventJSON, err)
	}
	calls := f.plan.snapshot()
	if len(calls) != 1 || calls[0].Input.Feedback != "less meetings" || !calls[0].Input.Force {
		t.Errorf("plan calls = %+v", calls)
	}
}

func TestRunner_RunNowWithAnotherInputQueuedIsNotClaimed(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.enqueueManual(t, "")
	_, err := f.runner.RunNow(context.Background(), mbID, automations.BuiltinInput{Date: "2026-10-21"})
	if !errors.Is(err, automations.ErrRunNotClaimed) {
		t.Errorf("RunNow = %v, want ErrRunNotClaimed", err)
	}
	if len(f.brief.snapshot()) != 0 {
		t.Error("RunNow ran the other queued input")
	}
}

func TestRenderOwnerCopy_LiteralPromptParsesAndFlows(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	brief := "Brief for %s on %s with a `backtick`, a \u2028 line separator,\na newline, \"quotes\", </script> and\n```\na fence."
	copyText := editedCopy(t, e, brief)
	if n := strings.Count(string(copyText), "builtin.defaultPrompt("); n != 1 {
		t.Errorf("builtin.defaultPrompt( appears %d times, want once (the helper's fallback)", n)
	}
	if _, err := automations.ParseRecipe(mbID, copyText, scopeOf(e)); err != nil {
		t.Fatalf("the rendered copy does not parse: %v", err)
	}
	f.writeCopy(t, copyText)
	f.sync(t)
	a := f.row(t)
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if o := f.slotOnce(t); o.Status != db.RunSucceeded {
		t.Fatalf("slot = %+v", o)
	}
	plan, _ := e.DefaultPrompt("plan", "")
	if calls := f.brief.snapshot(); len(calls) != 1 || calls[0].Prompt != brief {
		t.Errorf("brief got %+v, want the literal prompt", calls)
	}
	if calls := f.plan.snapshot(); len(calls) != 1 || calls[0].Prompt != plan {
		t.Error("plan did not get its default text")
	}
	if len(f.asked.all()) != 0 {
		t.Errorf("the copy asked for default prompts %v", f.asked.all())
	}
}

func TestRenderOwnerCopy_RefusesWrongPromptSet(t *testing.T) {
	e := mustEntry(t)
	for name, p := range map[string]map[string]string{
		"extra": {"brief": "x", "plan": "y", "other": "z"},
		"blank": {"brief": "x", "plan": "  "},
		"none":  {},
	} {
		if _, err := RenderOwnerCopy(e, p); err == nil {
			t.Errorf("%s: RenderOwnerCopy succeeded", name)
		}
	}
}

func TestRunner_RunNowWhileActiveCancelsItsRun(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	var (
		nowErr error
		nowRun int64
	)
	f.brief.during = func() {
		f.brief.during = nil
		_, nowErr = f.runner.RunNow(context.Background(), mbID, automations.BuiltinInput{Date: "2026-10-21"})
		for _, r := range f.runs(t) {
			if r.Trigger == db.TriggerManual {
				nowRun = r.ID
			}
		}
	}
	if o := f.slotOnce(t); o.Status != db.RunSucceeded {
		t.Fatalf("slot = %+v", o)
	}
	if !errors.Is(nowErr, automations.ErrRunNotClaimed) || nowRun == 0 {
		t.Fatalf("RunNow during the slot run = %v (run %d), want ErrRunNotClaimed", nowErr, nowRun)
	}
	run, err := f.d.GetAutomationRun(nowRun)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != db.RunCancelled {
		t.Errorf("the refused RunNow's run is %s, want cancelled", run.Status)
	}
	f.gate.due = false
	if o := f.slotOnce(t); o.Skipped != SkippedNotDue || len(f.brief.snapshot()) != 1 {
		t.Errorf("next slot = %+v, %d briefs; the refused input must never run", o, len(f.brief.snapshot()))
	}
}

func TestRenderOwnerCopy_UngivenPromptKeepsTheDefault(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	copyText, err := RenderOwnerCopy(e, map[string]string{"brief": "Only the brief for %s on %s."})
	if err != nil {
		t.Fatal(err)
	}
	f.writeCopy(t, copyText)
	f.sync(t)
	a := f.row(t)
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if o := f.slotOnce(t); o.Status != db.RunSucceeded {
		t.Fatalf("slot = %+v", o)
	}
	plan, _ := e.DefaultPrompt("plan", "")
	if c := f.brief.snapshot(); len(c) != 1 || c[0].Prompt != "Only the brief for %s on %s." {
		t.Error("brief did not get the inlined prompt")
	}
	if c := f.plan.snapshot(); len(c) != 1 || c[0].Prompt != plan {
		t.Error("plan did not get the shipped default")
	}
	if got := f.asked.all(); !slices.Equal(got, []string{"plan"}) {
		t.Errorf("defaultPrompt asked for %v, want [plan]", got)
	}
}

func TestRenderOwnerCopy_ChangesOnlyTheScript(t *testing.T) {
	e := mustEntry(t)
	e.Recipe = bytes.Replace(e.Recipe, []byte("when the\nbrief fails"), []byte("builtin.defaultPrompt(name) when the\nbrief fails"), 1)
	copyText := editedCopy(t, e, "Brief for %s on %s.")
	shipped, err := ParseShipped(e)
	if err != nil {
		t.Fatal(err)
	}
	r, err := automations.ParseRecipe(mbID, copyText, scopeOf(e))
	if err != nil {
		t.Fatal(err)
	}
	if r.Description != shipped.Description || !strings.Contains(r.Description, "builtin.defaultPrompt(name)") {
		t.Errorf("the description changed: %q", r.Description)
	}
}
