package builtin

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/aiconsent"
	"watchtower/internal/aiconsent/aiconsenttest"
	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// consentSwitch is a background-AI state a test flips.
type consentSwitch struct{ paused atomic.Bool }

func (c *consentSwitch) read() aiconsent.State {
	if c.paused.Load() {
		return aiconsent.Resolve(aiconsent.AnswerPaused, nil)
	}
	return aiconsent.Resolve(aiconsent.AnswerAllowed, nil)
}

// pauseAI makes aiconsent.Current — the default of the runner and of the
// fixture's executor — read a switch that starts paused, for this test.
func pauseAI(t *testing.T) *consentSwitch {
	t.Helper()
	sw := &consentSwitch{}
	sw.paused.Store(true)
	aiconsent.SetCurrentOverrideForTest(sw.read)
	t.Cleanup(aiconsenttest.AllowByDefault)
	return sw
}

// daemonProcess makes this test process's default origin background, as in
// the daemon that runs the slots, so only a ctx mark makes a call owner.
func daemonProcess(t *testing.T) {
	t.Helper()
	none := func(string) string { return "" }
	aiconsent.InitProcess("daemon", none)
	t.Cleanup(func() { aiconsent.InitProcess("", none) })
}

// count is the number of rows in table.
func (f *fixture) count(t *testing.T, table string) int {
	t.Helper()
	var n int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// flipGate is due and pauses background AI when asked.
type flipGate struct{ consent *consentSwitch }

func (g flipGate) Due(context.Context, Entry, time.Time) bool {
	g.consent.paused.Store(true)
	return true
}

// Which built-ins' indexed rows grant AI (automations.AutomationUsesAI),
// the rule the slot's paused skip reads.
func TestBuiltinRows_UseAI(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	want := map[string]bool{
		mbID: true, "track-my-threads": true, "idea-finder": true, reactionsID: true,
		waitingID: false, NeedsApprovalID: false, MailWaitingID: false,
		SlackTodayID: true,
	}
	for _, id := range allIDs() {
		w, ok := want[id]
		if !ok {
			t.Errorf("built-in %s: no expectation", id)
			continue
		}
		if got := automations.AutomationUsesAI(f.rowOf(t, id)); got != w {
			t.Errorf("%s uses AI = %v, want %v", id, got, w)
		}
	}
}

// BGAI-01: while background AI is paused an AI built-in's slot writes
// nothing — no gate call, no run row, no pipeline row.
func TestRunner_PausedSkipsAIBuiltinWritesNothing(t *testing.T) {
	daemonProcess(t)
	f := newFixture(t)
	f.sync(t)
	pauseAI(t)
	runs, pipes := f.count(t, "automation_runs"), f.count(t, "pipeline_runs")
	if o := f.slotOnce(t); o.Skipped != SkippedPaused || o.RunID != 0 || o.Status != "" {
		t.Errorf("slot = %+v, want skipped paused", o)
	}
	if f.gate.count() != 0 || len(f.brief.snapshot()) != 0 || len(f.plan.snapshot()) != 0 {
		t.Errorf("paused: %d gate calls, %d brief, %d plan calls; want none", f.gate.count(), len(f.brief.snapshot()), len(f.plan.snapshot()))
	}
	if r, p := f.count(t, "automation_runs"), f.count(t, "pipeline_runs"); r != runs || p != pipes {
		t.Errorf("rows: automation_runs %d→%d, pipeline_runs %d→%d; want unchanged", runs, r, pipes, p)
	}
}

// A built-in that calls no model runs at its slot while paused; Needs
// approval's run queued by its trigger is claimed by the executor.
func TestRunner_MechanicalBuiltinRunsWhilePaused(t *testing.T) {
	daemonProcess(t)
	f := newFixture(t)
	f.sync(t)
	gate := &fakeGate{due: true}
	f.runner.gates[waitingID] = gate
	f.runner.gates[MailWaitingID] = gate
	pauseAI(t)

	// The slot holds Waiting for me and Mail waiting; neither calls a model.
	out := f.runner.RunSlot(context.Background(), SlotWaitingForMe)
	if len(out) != 2 || gate.count() != 2 {
		t.Fatalf("Waiting for me slot = %+v, gate calls %d; want two succeeded sync runs", out, gate.count())
	}
	for _, o := range out {
		if o.Skipped != "" || o.Status != db.RunSucceeded {
			t.Fatalf("Waiting for me slot = %+v; want every run succeeded", out)
		}
	}
	run, err := f.d.GetAutomationRun(out[0].RunID)
	if err != nil {
		t.Fatal(err)
	}
	if run.Trigger != db.TriggerSync {
		t.Errorf("run trigger = %s, want sync", run.Trigger)
	}

	id, _, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: f.rowOf(t, NeedsApprovalID).ID,
		Trigger: db.TriggerEvent, EventCycle: "c1", Now: f.clock.Now(),
		EventJSON: `{"cycles":["action:7"],"events":[{"type":"approval","ref":"action:7"}],"count":1,"truncated":false}`})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.exec.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	f.exec.Wait()
	if run, err = f.d.GetAutomationRun(id); err != nil {
		t.Fatal(err)
	}
	if run.Status != db.RunSucceeded {
		t.Errorf("Needs approval run = %s/%s %q; want succeeded", run.Status, run.ErrorKind, run.Error)
	}
}

// BGAI-02: a Run Now queued for the slot runs while paused, on the owner's
// behalf, without asking the gate.
func TestRunner_PausedStillRunsQueuedRunNow(t *testing.T) {
	daemonProcess(t)
	f := newFixture(t)
	f.sync(t)
	pauseAI(t)
	id, _ := f.enqueueManual(t, "")
	o := f.slotOnce(t)
	if o.RunID != id || o.Status != db.RunSucceeded || o.Skipped != "" || f.gate.count() != 0 {
		t.Fatalf("slot = %+v, gate calls %d; want the queued run executed, no gate", o, f.gate.count())
	}
	f.brief.mu.Lock()
	origins := append([]aiconsent.Origin(nil), f.brief.origins...)
	f.brief.mu.Unlock()
	if len(origins) != 1 || origins[0] != aiconsent.OriginOwner {
		t.Errorf("brief call origins = %v, want one owner call", origins)
	}
}

// A pause while the gate reads still writes no row: the slot checks again
// before it queues the sync run.
func TestRunner_PauseDuringGateWritesNoRun(t *testing.T) {
	daemonProcess(t)
	f := newFixture(t)
	f.sync(t)
	sw := pauseAI(t)
	sw.paused.Store(false)
	f.runner.gates[mbID] = flipGate{consent: sw}
	if o := f.slotOnce(t); o.Skipped != SkippedPaused || o.RunID != 0 {
		t.Fatalf("slot = %+v; want skipped paused", o)
	}
	if n := len(f.runs(t)); n != 0 || len(f.brief.snapshot()) != 0 {
		t.Errorf("%d runs, %d brief calls; want none", n, len(f.brief.snapshot()))
	}
}

// A sync run the executor claimed under consent finishes after a pause
// (D12): its later model calls are admitted, not refused.
func TestRunner_AdmittedSyncRunFinishesAfterPause(t *testing.T) {
	daemonProcess(t)
	f := newFixture(t)
	f.sync(t)
	sw := pauseAI(t)
	sw.paused.Store(false)
	f.brief.during = func() { sw.paused.Store(true) }
	o := f.slotOnce(t)
	if o.Status != db.RunSucceeded || o.Skipped != "" {
		t.Fatalf("slot = %+v; want the sync run to finish", o)
	}
	f.plan.mu.Lock()
	checks := append([]error(nil), f.plan.checks...)
	f.plan.mu.Unlock()
	if len(checks) != 1 || checks[0] != nil {
		t.Errorf("plan call consent checks after the pause = %v; want one admitted call", checks)
	}
}
