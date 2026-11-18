package builtin

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/aiconsent"
	"watchtower/internal/aiconsent/aiconsenttest"
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

func TestEntry_UsesAI(t *testing.T) {
	want := map[string]bool{
		mbID: true, "track-my-threads": true, "idea-finder": true, reactionsID: true,
		waitingID: false, NeedsApprovalID: false,
	}
	for _, e := range All() {
		w, ok := want[e.ID]
		if !ok {
			t.Errorf("built-in %s: no expectation", e.ID)
			continue
		}
		if got := e.UsesAI(); got != w {
			t.Errorf("%s.UsesAI() = %v, want %v", e.ID, got, w)
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
	pauseAI(t)

	out := f.runner.RunSlot(context.Background(), SlotWaitingForMe)
	if len(out) != 1 || out[0].Skipped != "" || out[0].Status != db.RunSucceeded || gate.count() != 1 {
		t.Fatalf("Waiting for me slot = %+v, gate calls %d; want one succeeded sync run", out, gate.count())
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

// A sync run the slot started under consent is admitted: the owner's pause
// after the slot's check does not cancel it (D12).
func TestRunner_AdmittedSyncRunFinishesAfterPause(t *testing.T) {
	daemonProcess(t)
	f := newFixture(t)
	f.sync(t)
	sw := pauseAI(t)
	sw.paused.Store(false)
	f.runner.gates[mbID] = flipGate{consent: sw}
	o := f.slotOnce(t)
	if o.Status != db.RunSucceeded || o.Skipped != "" {
		t.Fatalf("slot = %+v; want the sync run to finish", o)
	}
	if n := len(f.brief.snapshot()); n != 1 {
		t.Errorf("brief calls = %d, want 1", n)
	}
}
