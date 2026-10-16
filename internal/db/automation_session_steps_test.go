package db

import (
	"errors"
	"testing"
)

// seedSessionStepRun is a workbench automation's run waiting for the app
// with one open session step; it returns the workbench, run and step ids.
func seedSessionStepRun(t *testing.T, d *DB, slug string) (wb, run, step int64) {
	t.Helper()
	wb, err := d.CreateWorkbench("acme-"+slug, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	a := seedRunAutomation(t, d, slug, 1)
	if _, err := d.Exec(`UPDATE automations SET scope = 'workbench', project_id = ? WHERE id = ?`, wb, a); err != nil {
		t.Fatal(err)
	}
	run, _ = mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	if !mustClaimAutomationRun(t, d, run) {
		t.Fatal("claim lost")
	}
	if err := d.SetAutomationRunWaiting(run, WaitApp); err != nil {
		t.Fatal(err)
	}
	step, err = d.AppendAutomationRunStep(AutomationRunStep{RunID: run, Kind: "session", Name: "claude",
		ArgsJSON: `{"prompt":"Review","agent":"claude","title":"⚙ Review · run #1"}`, Status: "waiting", StartedAt: runTestNow})
	if err != nil {
		t.Fatal(err)
	}
	return wb, run, step
}

// seedRunSession is a terminal session of workbench wb started by run.
func seedRunSession(t *testing.T, d *DB, wb, run int64) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, automation_run_id)
		VALUES (?, 'claude', 'Review', '/tmp/acme', 'uuid', ?)`, wb, run)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func mustAttach(t *testing.T, d *DB, step, session int64) bool {
	t.Helper()
	ok, err := d.AttachAutomationSessionStep(step, session)
	if err != nil {
		t.Fatalf("AttachAutomationSessionStep(%d, %d): %v", step, session, err)
	}
	return ok
}

func TestSessionAttach_IsConditional(t *testing.T) {
	d := openTestDB(t)
	wb, run, step := seedSessionStepRun(t, d, "review")
	pending, err := d.PendingAutomationSessionSteps()
	if err != nil || len(pending) != 1 || pending[0].StepID != step || pending[0].RunID != run || pending[0].WorkbenchID != wb {
		t.Fatalf("pending = %+v, %v; want step %d of run %d in workbench %d", pending, err, step, run, wb)
	}

	// Two attaches of the same step, each with its own session row: one wins.
	first, second := seedRunSession(t, d, wb, run), seedRunSession(t, d, wb, run)
	if !mustAttach(t, d, step, first) || mustAttach(t, d, step, second) {
		t.Fatal("want exactly the first attach to land")
	}
	got, err := d.GetAutomationSessionStep(step)
	if err != nil || got.SessionID != first || got.Status != "waiting" || got.SessionGone {
		t.Fatalf("step = %+v, %v; want waiting with session %d", got, err, first)
	}
	if pending, _ := d.PendingAutomationSessionSteps(); len(pending) != 0 {
		t.Fatalf("an attached step is still pending: %+v", pending)
	}

	// A session row of another run never attaches.
	wb2, run2, step2 := seedSessionStepRun(t, d, "deploy")
	if mustAttach(t, d, step2, seedRunSession(t, d, wb2, run)) {
		t.Fatal("a session of another run attached")
	}
	// Nor does an unknown session row.
	if mustAttach(t, d, step2, 9999) {
		t.Fatal("an unknown session attached")
	}

	// A cancelled run's step never attaches.
	own := seedRunSession(t, d, wb2, run2)
	if ok, err := d.CancelAutomationRun(run2, runTestNow); err != nil || !ok {
		t.Fatalf("cancel = (%v, %v)", ok, err)
	}
	if mustAttach(t, d, step2, own) {
		t.Fatal("a cancelled run's step attached")
	}
}

// Attach needs the run still waiting for the app: once its wait moved to
// session, a later attach (another step of it) is refused.
func TestSessionAttach_NeedsRunWaitingForApp(t *testing.T) {
	d := openTestDB(t)
	wb, run, step := seedSessionStepRun(t, d, "review")
	if err := d.SetAutomationRunWaiting(run, WaitSession); err != nil {
		t.Fatal(err)
	}
	if mustAttach(t, d, step, seedRunSession(t, d, wb, run)) {
		t.Fatal("attached while the run waits for a session, not the app")
	}
}

func TestSessionEnded_OnlyFromWaiting(t *testing.T) {
	d := openTestDB(t)
	_, run, step := seedSessionStepRun(t, d, "review")
	ok, err := d.EndAutomationSessionStep(step, SessionStepLaunchFailed, "Codex was not found")
	if err != nil || !ok {
		t.Fatalf("end = (%v, %v); want true", ok, err)
	}
	got, err := d.GetAutomationSessionStep(step)
	if err != nil || got.Status != "error" || got.Error != "Codex was not found" {
		t.Fatalf("step = %+v, %v; want error with the Desktop's reason", got, err)
	}
	if ok, err := d.EndAutomationSessionStep(step, SessionStepStopped, ""); err != nil || ok {
		t.Fatalf("second end = (%v, %v); want false", ok, err)
	}

	// A step already closed ok is never ended.
	okStep := mustAppendAutomationRunStep(t, d, run, "session", "waiting")
	if err := d.FinishAutomationRunStep(okStep, StepFinish{Status: "ok", Now: runTestNow}); err != nil {
		t.Fatal(err)
	}
	if ok, err := d.EndAutomationSessionStep(okStep, SessionStepStopped, ""); err != nil || ok {
		t.Fatalf("end of an ok step = (%v, %v); want false", ok, err)
	}
	// Nor a waiting step of another kind (an ask).
	ask := mustAppendAutomationRunStep(t, d, run, "ask", "waiting")
	if ok, err := d.EndAutomationSessionStep(ask, SessionStepStopped, ""); err != nil || ok {
		t.Fatalf("end of an ask step = (%v, %v); want false", ok, err)
	}
	if _, err := d.EndAutomationSessionStep(step, "later", ""); err == nil {
		t.Fatal("an unknown end status was accepted")
	}
}

func TestSessionStep_ReadsTheAttachedSession(t *testing.T) {
	d := openTestDB(t)
	wb, run, step := seedSessionStepRun(t, d, "review")
	sess := seedRunSession(t, d, wb, run)
	if !mustAttach(t, d, step, sess) {
		t.Fatal("attach lost")
	}
	if _, err := d.Exec(`UPDATE terminal_sessions SET finished_at = '2026-10-14T12:00:00.000Z', finish_summary = 'LGTM',
		agent_failed_at = '2026-10-14T12:00:00.000Z', agent_error = 'overloaded' WHERE id = ?`, sess); err != nil {
		t.Fatal(err)
	}
	got, err := d.GetAutomationSessionStep(step)
	want := AutomationSessionStep{Status: "waiting", SessionID: sess, Finished: true, FinishSummary: "LGTM", Failed: true, AgentError: "overloaded"}
	if err != nil || got != want {
		t.Fatalf("step = %+v, %v; want %+v", got, err, want)
	}
	if _, err := d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sess); err != nil {
		t.Fatal(err)
	}
	if got, _ := d.GetAutomationSessionStep(step); !got.SessionGone || got.SessionID != sess {
		t.Fatalf("step = %+v; want the session gone", got)
	}
	if _, err := d.GetAutomationSessionStep(step + 100); !errors.Is(err, ErrAutomationRunStepNotFound) {
		t.Fatalf("unknown step err = %v; want ErrAutomationRunStepNotFound", err)
	}
}

// A personal automation's session step (P1 refuses session: entries, so
// only a hand-made row) is never offered to the Desktop.
func TestSessionPending_OnlyWorkbenchRuns(t *testing.T) {
	d := openTestDB(t)
	_, run := seedRunningAutomationRun(t, d)
	if err := d.SetAutomationRunWaiting(run, WaitApp); err != nil {
		t.Fatal(err)
	}
	mustAppendAutomationRunStep(t, d, run, "session", "waiting")
	if pending, err := d.PendingAutomationSessionSteps(); err != nil || len(pending) != 0 {
		t.Fatalf("pending = %+v, %v; want none for a personal run", pending, err)
	}
}
