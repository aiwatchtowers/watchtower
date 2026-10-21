package db

import (
	"testing"
	"time"
)

// seedResumableRun makes a confirmed, enabled automation and a run of it
// claimed at its approval hash that made one ok call (recorded) and waits in
// its second (a pending record), as a run left waiting by a daemon stop.
func seedResumableRun(t *testing.T, d *DB, slug string) (automationID, runID int64) {
	t.Helper()
	automationID = seedRunAutomation(t, d, slug, 1)
	hash := "h-" + slug
	if err := d.ConfirmAutomation(automationID, hash, runTestNow); err != nil {
		t.Fatal(err)
	}
	if err := d.SetAutomationEnabled(automationID, true, runTestNow); err != nil {
		t.Fatal(err)
	}
	runID, _ = mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: automationID, Trigger: TriggerManual})
	if ok, err := d.ClaimAutomationRun(runID, hash, "snapshot", 50000, 5, runTestNow); err != nil || !ok {
		t.Fatalf("claim = (%v, %v)", ok, err)
	}
	ok := `{"n":1}`
	first := appendStep(t, d, runID, "state")
	if err := d.FinishAutomationRunStep(first, StepFinish{Status: "ok", Now: runTestNow,
		Replay: &AutomationRunReplay{RunID: runID, Seq: 1, Kind: "state", Name: "get", ArgsHash: "a1", ResultJSON: &ok}}); err != nil {
		t.Fatal(err)
	}
	second := appendStep(t, d, runID, "ask")
	if err := d.MarkAutomationRunStep(second, "waiting", StepFinish{AskID: 7,
		Replay: &AutomationRunReplay{RunID: runID, Seq: 2, Kind: "ask", Name: "question", ArgsHash: "a2", Pending: true}}); err != nil {
		t.Fatal(err)
	}
	if err := d.SetAutomationRunWaiting(runID, WaitAsk); err != nil {
		t.Fatal(err)
	}
	return automationID, runID
}

func appendStep(t *testing.T, d *DB, runID int64, kind string) int64 {
	t.Helper()
	id, err := d.AppendAutomationRunStep(AutomationRunStep{RunID: runID, Kind: kind, Status: "ok", StartedAt: runTestNow})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func countReplay(t *testing.T, d *DB, runID int64) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM automation_run_replay WHERE run_id = ?`, runID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// TestAuto08_RestartKeepsResumableWaitingRun: the start sweep keeps a
// resumable waiting run (status waiting, resume_pending) and still ends
// every other active run, including a waiting run that cannot resume.
func TestAuto08_RestartKeepsResumableWaitingRun(t *testing.T) {
	d := openTestDB(t)
	_, kept := seedResumableRun(t, d, "kept")
	_, gap := seedResumableRun(t, d, "gap") // its first record is lost: the log does not cover the wait
	if _, err := d.Exec(`DELETE FROM automation_run_replay WHERE run_id = ? AND seq = 1`, gap); err != nil {
		t.Fatal(err)
	}
	_, flagged := seedResumableRun(t, d, "flagged")
	if err := d.SetAutomationRunNotResumable(flagged); err != nil {
		t.Fatal(err)
	}
	reconfirmed, changed := seedResumableRun(t, d, "changed")
	if _, err := d.Exec(`UPDATE automations SET approval_hash = 'h-new', confirmed_hash = 'h-new' WHERE id = ?`, reconfirmed); err != nil {
		t.Fatal(err)
	}
	disabledID, disabled := seedResumableRun(t, d, "disabled")
	if err := d.SetAutomationEnabled(disabledID, false, runTestNow); err != nil {
		t.Fatal(err)
	}
	running := seedRunAutomation(t, d, "running", 1)
	busy, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: running, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, busy)

	if n, err := d.MarkInterruptedAutomationRuns(runTestNow); err != nil || n != 5 {
		t.Fatalf("MarkInterruptedAutomationRuns = (%d, %v); want 5 ended", n, err)
	}
	r := wantAutomationRun(t, d, kept, RunWaiting, "")
	if !r.ResumePending || r.WaitingReason != WaitAsk || r.FinishedAt != nil {
		t.Fatalf("kept run = %+v; want waiting (ask) and resume_pending", r)
	}
	for _, id := range []int64{gap, flagged, changed, disabled, busy} {
		if r := wantAutomationRun(t, d, id, RunFailed, ErrKindInterrupted); r.ResumePending {
			t.Errorf("run %d ended but still resume_pending", id)
		}
	}
	if next, err := d.NextResumePendingAutomationRuns(); err != nil || len(next) != 1 || next[0].ID != kept {
		t.Fatalf("NextResumePendingAutomationRuns = %+v, %v; want only %d", next, err, kept)
	}
	steps, err := d.ListAutomationRunSteps(kept)
	if err != nil || len(steps) != 2 || steps[1].FinishedAt != nil || steps[1].Status != "waiting" {
		t.Fatalf("kept run's steps = %+v, %v; want its waiting step still open", steps, err)
	}
}

// TestAuto08_ReplayLogDeletedOnFinish: any terminal status deletes the run's
// replay log in the same write.
func TestAuto08_ReplayLogDeletedOnFinish(t *testing.T) {
	d := openTestDB(t)
	ends := map[string]func(id int64) error{
		"finish": func(id int64) error {
			return d.FinishAutomationRun(id, RunFinish{Status: RunSucceeded, Now: runTestNow}, nil)
		},
		"cancel": func(id int64) error { _, err := d.CancelAutomationRun(id, runTestNow); return err },
	}
	for name, end := range ends {
		_, id := seedResumableRun(t, d, name)
		if n := countReplay(t, d, id); n != 2 {
			t.Fatalf("%s: replay rows = %d; want 2", name, n)
		}
		if _, err := d.MarkInterruptedAutomationRuns(runTestNow); err != nil {
			t.Fatal(err)
		}
		if r := mustGetAutomationRun(t, d, id); !r.ResumePending {
			t.Fatalf("%s: the start sweep did not keep the run", name)
		}
		if err := end(id); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if n := countReplay(t, d, id); n != 0 {
			t.Errorf("%s: replay rows after the end = %d; want 0", name, n)
		}
		if r := mustGetAutomationRun(t, d, id); r.ResumePending {
			t.Errorf("%s: resume_pending still set after the end", name)
		}
	}
	_, swept := seedResumableRun(t, d, "swept")
	if err := d.SetAutomationRunNotResumable(swept); err != nil {
		t.Fatal(err)
	}
	if _, err := d.MarkInterruptedAutomationRuns(runTestNow); err != nil {
		t.Fatal(err)
	}
	if n := countReplay(t, d, swept); n != 0 {
		t.Errorf("swept: replay rows after the restart sweep = %d; want 0", n)
	}
}

func TestClaimResumeAutomationRun_SlotAndState(t *testing.T) {
	d := openTestDB(t)
	_, id := seedResumableRun(t, d, "kept")
	other := seedRunAutomation(t, d, "busy", 1)
	busy, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: other, Trigger: TriggerManual})
	if _, err := d.MarkInterruptedAutomationRuns(runTestNow); err != nil {
		t.Fatal(err)
	}
	mustClaimAutomationRun(t, d, busy)
	if ok, err := d.ClaimResumeAutomationRun(id, 1); err != nil || ok {
		t.Fatalf("claim with no free slot = (%v, %v); want false", ok, err)
	}
	if ok, err := d.ClaimResumeAutomationRun(id, 2); err != nil || !ok {
		t.Fatalf("claim = (%v, %v); want true", ok, err)
	}
	r := wantAutomationRun(t, d, id, RunRunning, "")
	if r.ResumePending || r.WaitingReason != "" {
		t.Fatalf("claimed run = %+v; want running, no longer resume_pending", r)
	}
	if ok, err := d.ClaimResumeAutomationRun(id, 2); err != nil || ok {
		t.Fatalf("second claim = (%v, %v); want false", ok, err)
	}
	if err := d.SetAutomationRunWaiting(id, WaitAsk); err != nil { // a stop during the replay
		t.Fatal(err)
	}
	wantAutomationRun(t, d, id, RunWaiting, "")
}

// TestReplay_StepFinishWritesItsRecord: the replay row lands with the
// step's close; a close the step refuses (already finished) writes none.
func TestReplay_StepFinishWritesItsRecord(t *testing.T) {
	d := openTestDB(t)
	_, id := seedResumableRun(t, d, "kept")
	recs, err := d.ListAutomationRunReplay(id)
	if err != nil || len(recs) != 2 {
		t.Fatalf("records = %+v, %v", recs, err)
	}
	if recs[0].Pending || recs[0].ResultJSON == nil || *recs[0].ResultJSON != `{"n":1}` || recs[0].ClockJSON != "[]" {
		t.Errorf("record 1 = %+v", recs[0])
	}
	if !recs[1].Pending || recs[1].ResultJSON != nil || recs[1].ArgsHash != "a2" {
		t.Errorf("record 2 = %+v; want the pending wait", recs[1])
	}
	steps, err := d.ListAutomationRunSteps(id)
	if err != nil {
		t.Fatal(err)
	}
	ans := `{"answers":[]}`
	if err := d.FinishAutomationRunStep(steps[1].ID, StepFinish{Status: "ok", Now: runTestNow.Add(time.Minute),
		Replay: &AutomationRunReplay{RunID: id, Seq: 2, Kind: "ask", Name: "question", ArgsHash: "a2", ResultJSON: &ans}}); err != nil {
		t.Fatal(err)
	}
	err = d.FinishAutomationRunStep(steps[1].ID, StepFinish{Status: "ok", Now: runTestNow.Add(time.Minute),
		Replay: &AutomationRunReplay{RunID: id, Seq: 3, Kind: "log", Name: "log", ArgsHash: "x"}})
	if err == nil {
		t.Fatal("a second finish was accepted")
	}
	recs, _ = d.ListAutomationRunReplay(id)
	if len(recs) != 2 || recs[1].Pending || recs[1].ResultJSON == nil || *recs[1].ResultJSON != ans {
		t.Fatalf("records after the close = %+v; want record 2 complete and no record 3", recs)
	}
}
