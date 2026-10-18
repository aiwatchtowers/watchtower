package automations_test

import (
	"fmt"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// Board #562: per-run resource bounds and finish/journal failure paths.

// TestAuto08_StepCapEndsTheRun: a script that catches every error in an SDK
// loop is ended by the step cap — one error step past MaxStepsPerRun, the run
// failed/script, nothing committed.
func TestAuto08_StepCapEndsTheRun(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `state.set("k", 1); while (true) { try { state.get("k") } catch (e) {} }`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunFailed, db.ErrKindScript)
	if !strings.Contains(r.Error, fmt.Sprintf("more than %d SDK calls", automations.MaxStepsPerRun)) {
		t.Fatalf("error = %q; want the step cap", r.Error)
	}
	steps := f.steps(t, id)
	if len(steps) != automations.MaxStepsPerRun+1 {
		t.Fatalf("steps = %d; want %d", len(steps), automations.MaxStepsPerRun+1)
	}
	if last := steps[len(steps)-1]; last.Status != automations.StepError || !strings.Contains(last.Error, "SDK calls") {
		t.Fatalf("last step = %s %q; want the cap's error step", last.Status, last.Error)
	}
	if n := f.count(t, "automation_state"); n != 0 {
		t.Fatalf("automation_state rows = %d; want 0 (a failed run commits nothing)", n)
	}
}

// TestOutputs_CapPerRun: the output past MaxOutputsPerRun is a catchable
// ValidationError; the run commits exactly MaxOutputsPerRun outputs.
func TestOutputs_CapPerRun(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `let refused = "";
		for (let i = 0; i < 60; i++) {
			try { output.inbox({title: "t" + i, body: "b"}) } catch (e) { refused = refused || e.name + ": " + e.message }
		}
		return refused`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunSucceeded, "")
	if !strings.Contains(r.Summary, "ValidationError") || !strings.Contains(r.Summary, fmt.Sprint(automations.MaxOutputsPerRun)) {
		t.Fatalf("summary = %q; want the outputs cap's ValidationError", r.Summary)
	}
	if n := f.count(t, "automation_outputs"); n != automations.MaxOutputsPerRun {
		t.Fatalf("outputs = %d; want %d", n, automations.MaxOutputsPerRun)
	}
}

// TestSession_CapPerRun: the session() call past MaxSessionCalls is a
// ValidationError step; the earlier ones run (dry_run here).
func TestSession_CapPerRun(t *testing.T) {
	rep := sessDryRun(t, []string{"session:start"}, `let out = [];
		for (let i = 0; i < 4; i++) {
			try { out.push(session({prompt: "x"}).status) } catch (e) { out.push(e.name) }
		}
		return out.join(",")`, sessWorkbenchScope)
	var got []string
	for _, s := range rep.Steps {
		if s.Kind == automations.StepKindSession {
			got = append(got, s.Status)
		}
	}
	want := []string{automations.StepDryRun, automations.StepDryRun, automations.StepDryRun, automations.StepError}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("session steps = %v; want %v", got, want)
	}
	last := rep.Steps[len(rep.Steps)-1]
	if !strings.Contains(last.Error, "ValidationError") || !strings.Contains(last.Error, fmt.Sprintf("more than %d times", automations.MaxSessionCalls)) {
		t.Fatalf("last step error = %q; want the session cap", last.Error)
	}
}

// failOutputsTrigger makes every automation_outputs insert fail, so a
// succeeded run's commit is refused.
const failOutputsTrigger = `CREATE TRIGGER test_fail_outputs BEFORE INSERT ON automation_outputs
	BEGIN SELECT RAISE(ABORT, 'injected output failure'); END`

// TestAuto08_FinishFailureRetries: a refused finish is retried; once the
// cause goes away the run finishes as it ended, its commit included.
func TestAuto08_FinishFailureRetries(t *testing.T) {
	f := newExFixture(t, exOpts{})
	if _, err := f.d.Exec(failOutputsTrigger); err != nil {
		t.Fatal(err)
	}
	var attempts []int
	automations.SetExecutorFinishPause(f.e, func(attempt int) {
		attempts = append(attempts, attempt)
		if attempt == 2 {
			if _, err := f.d.Exec(`DROP TRIGGER test_fail_outputs`); err != nil {
				t.Error(err)
			}
		}
	})
	a := f.seed(t, "digest", `output.inbox({title: "t", body: "b"}); state.set("cursor", 7); return 1`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if fmt.Sprint(attempts) != "[1 2]" {
		t.Fatalf("pauses = %v; want [1 2]", attempts)
	}
	if f.count(t, "automation_outputs") != 1 || f.count(t, "automation_state") != 1 {
		t.Fatalf("committed = %s; want the output and the state", f.dump(t))
	}
}

// TestAuto08_FinishFailureEndsTheRunFailed: when every finish attempt is
// refused the run still ends — failed/backend without its commit — so it
// does not hold its concurrency slot until the daemon restarts.
func TestAuto08_FinishFailureEndsTheRunFailed(t *testing.T) {
	f := newExFixture(t, exOpts{})
	if _, err := f.d.Exec(failOutputsTrigger); err != nil {
		t.Fatal(err)
	}
	pauses := 0
	automations.SetExecutorFinishPause(f.e, func(int) { pauses++ })
	a := f.seed(t, "digest", `output.inbox({title: "t", body: "b"}); state.set("cursor", 7); return 1`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunFailed, db.ErrKindBackend)
	if !strings.Contains(r.Error, "could not be finished as succeeded") || !strings.Contains(r.Error, "injected output failure") {
		t.Fatalf("error = %q; want the finish failure", r.Error)
	}
	if pauses != 3 {
		t.Fatalf("pauses = %d; want 3 retries", pauses)
	}
	if f.count(t, "automation_outputs") != 0 || f.count(t, "automation_state") != 0 {
		t.Fatalf("committed = %s; want nothing (AUTO-04)", f.dump(t))
	}
	// The automation's slot (concurrency 1) is free: its next run is
	// claimed and ends too.
	next := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, next, db.RunFailed, db.ErrKindBackend)
}

// TestAuto04_JournalErrorAfterSuccessStillCommits: a step row that could not
// be written does not fail a script that succeeded — its writes already
// happened, so dropping its state would make the next run repeat them. The
// run commits and its error notes the incomplete journal.
func TestAuto04_JournalErrorAfterSuccessStillCommits(t *testing.T) {
	f := newExFixture(t, exOpts{})
	if _, err := f.d.Exec(`CREATE TRIGGER test_fail_log_step BEFORE INSERT ON automation_run_steps
		WHEN NEW.kind = 'log' BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END`); err != nil {
		t.Fatal(err)
	}
	a := f.seed(t, "digest", `log("sent"); state.set("cursor", 7); return 1`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunSucceeded, "")
	if !strings.Contains(r.Error, "journal is incomplete") || !strings.Contains(r.Error, "injected journal failure") {
		t.Fatalf("error = %q; want the incomplete-journal note", r.Error)
	}
	if !strings.Contains(f.dump(t), `{"cursor":7}`) {
		t.Fatalf("state = %s; want the cursor committed", f.dump(t))
	}
}
