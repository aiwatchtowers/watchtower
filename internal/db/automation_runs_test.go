package db

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// runTestNow is a fixed instant for run tests (only ordering matters).
var runTestNow = time.Now().UTC().Truncate(time.Second)

func seedRunAutomation(t *testing.T, d *DB, slug string, concurrency int) int64 {
	t.Helper()
	id := seedAutomationRow(t, d, slug, "/acme/automations/"+slug+".md", "h-"+slug)
	if _, err := d.Exec(`UPDATE automations SET concurrency = ? WHERE id = ?`, concurrency, id); err != nil {
		t.Fatal(err)
	}
	return id
}

func mustEnqueueAutomationRun(t *testing.T, d *DB, r EnqueueRequest) (int64, bool) {
	t.Helper()
	if r.Now.IsZero() {
		r.Now = runTestNow
	}
	id, coalesced, err := d.EnqueueAutomationRun(r)
	if err != nil {
		t.Fatalf("EnqueueAutomationRun(%+v): %v", r, err)
	}
	return id, coalesced
}

func mustClaimAutomationRun(t *testing.T, d *DB, runID int64) bool {
	t.Helper()
	ok, err := d.ClaimAutomationRun(runID, "hash", "snapshot", 50000, 5, runTestNow)
	if err != nil {
		t.Fatalf("ClaimAutomationRun(%d): %v", runID, err)
	}
	return ok
}

func mustGetAutomationRun(t *testing.T, d *DB, id int64) *AutomationRun {
	t.Helper()
	r, err := d.GetAutomationRun(id)
	if err != nil {
		t.Fatalf("GetAutomationRun(%d): %v", id, err)
	}
	return r
}

func countAutomationTableRows(t *testing.T, d *DB, table string) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestEnqueue_InsertsQueued(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	id, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	if coalesced {
		t.Error("first enqueue coalesced")
	}
	r := mustGetAutomationRun(t, d, id)
	if r.Status != RunQueued || !r.QueuedAt.Equal(runTestNow) || r.Trigger != TriggerManual || r.StartedAt != nil {
		t.Errorf("run = %+v; want queued at %v", r, runTestNow)
	}
	if _, _, err := d.EnqueueAutomationRun(EnqueueRequest{AutomationID: a, Trigger: TriggerButton}); err == nil {
		t.Error("enqueue with zero Now accepted")
	}
}

func TestRun_CoalescesSecondTrigger(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	first, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	second, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	if second != first || !coalesced {
		t.Errorf("second manual = (%d, %v); want (%d, true)", second, coalesced, first)
	}
	button, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerButton})
	if button == first || coalesced {
		t.Errorf("button = (%d, %v); want a new row", button, coalesced)
	}
	if n := countAutomationTableRows(t, d, "automation_runs"); n != 2 {
		t.Errorf("rows = %d; want 2", n)
	}
}

func TestEnqueue_EventCycleOncePerAutomation(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "watch", 1)
	first, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerEvent, EventCycle: "c1",
		EventJSON: `{"cycles":["c1"],"events":[],"count":0,"truncated":false}`})
	if !mustClaimAutomationRun(t, d, first) {
		t.Fatal("claim failed")
	}
	if err := d.FinishAutomationRun(first, RunFinish{Status: RunSucceeded, Now: runTestNow}, nil); err != nil {
		t.Fatal(err)
	}
	again, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerEvent, EventCycle: "c1"})
	if again != first || !coalesced {
		t.Errorf("same cycle after finish = (%d, %v); want (%d, true)", again, coalesced, first)
	}
	if n := countAutomationTableRows(t, d, "automation_runs"); n != 1 {
		t.Errorf("rows = %d; want 1", n)
	}
}

func TestEnqueue_EventCycleMergedIntoEarlierRunIsCoalesced(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "watch", 1)
	res, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, event_cycle, event_json, status, finished_at)
		VALUES (?, 'event', 'A', '{"cycles":["A","B"],"events":[],"count":2,"truncated":false}', 'succeeded', ?)`,
		a, formatAutomationTime(runTestNow))
	if err != nil {
		t.Fatal(err)
	}
	seeded, _ := res.LastInsertId()
	id, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerEvent, EventCycle: "B"})
	if id != seeded || !coalesced {
		t.Errorf("cycle B = (%d, %v); want (%d, true)", id, coalesced, seeded)
	}
	if n := countAutomationTableRows(t, d, "automation_runs"); n != 1 {
		t.Errorf("rows = %d; want 1", n)
	}
	// A malformed event_json of another run never breaks the lookup.
	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, event_json, status)
		VALUES (?, 'event', '{', 'failed')`, a); err != nil {
		t.Fatal(err)
	}
	if _, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerEvent, EventCycle: "C"}); coalesced {
		t.Error("new cycle C coalesced")
	}
}

func TestEnqueue_EventCycleCheckedBeforeQueuedCoalescing(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "watch", 1)
	queued, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerEvent, EventCycle: "A"})
	for _, cycle := range []string{"A", "B"} {
		id, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerEvent, EventCycle: cycle})
		if id != queued || !coalesced {
			t.Errorf("cycle %s = (%d, %v); want (%d, true)", cycle, id, coalesced, queued)
		}
	}
	if r := mustGetAutomationRun(t, d, queued); r.EventCycle != "A" {
		t.Errorf("event_cycle = %q; want A untouched", r.EventCycle)
	}
	if n := countAutomationTableRows(t, d, "automation_runs"); n != 1 {
		t.Errorf("rows = %d; want 1", n)
	}
}

func TestEnqueue_AdvancesScheduleAtomically(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "daily", 1)
	due1, due2 := runTestNow.Add(-time.Hour), runTestNow
	next := runTestNow.Add(24 * time.Hour)
	mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule, ScheduledFor: &due1,
		AdvanceScheduleTo: &due1, NextRunAt: &due2})
	_, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule, ScheduledFor: &due2,
		AdvanceScheduleTo: &due2, NextRunAt: &next})
	if !coalesced {
		t.Fatal("second schedule enqueue not coalesced")
	}
	got := mustGetAutomation(t, d, a)
	if got.LastScheduledFor == nil || !got.LastScheduledFor.Equal(due2) || got.NextRunAt == nil || !got.NextRunAt.Equal(next) {
		t.Errorf("schedule = (%v, %v); want (%v, %v)", got.LastScheduledFor, got.NextRunAt, due2, next)
	}
	if _, _, err := d.EnqueueAutomationRun(EnqueueRequest{AutomationID: 999, Trigger: TriggerSchedule,
		AdvanceScheduleTo: &due2, Now: runTestNow}); err == nil {
		t.Error("enqueue for a missing automation succeeded")
	}
}

func TestAuto05_OneActiveRunPerAutomation(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	r1, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	r2, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerButton})
	if !mustClaimAutomationRun(t, d, r1) {
		t.Fatal("first claim lost")
	}
	if mustClaimAutomationRun(t, d, r2) {
		t.Fatal("second claim won while the first runs")
	}
	if err := d.SetAutomationRunWaiting(r1, WaitApproval); err != nil {
		t.Fatal(err)
	}
	if mustClaimAutomationRun(t, d, r2) {
		t.Fatal("second claim won while the first waits")
	}
	if err := d.FinishAutomationRun(r1, RunFinish{Status: RunSucceeded, Now: runTestNow}, nil); err != nil {
		t.Fatal(err)
	}
	if !mustClaimAutomationRun(t, d, r2) {
		t.Fatal("second claim lost after the first finished")
	}
	r := mustGetAutomationRun(t, d, r2)
	if r.Status != RunRunning || r.RecipeHash != "hash" || r.RecipeSnapshot != "snapshot" ||
		r.BudgetTokens != 50000 || r.BudgetMinutes != 5 || r.StartedAt == nil {
		t.Errorf("claimed run = %+v", r)
	}
	if mustClaimAutomationRun(t, d, r2) {
		t.Error("a running run was claimed again")
	}
	if _, err := d.ClaimAutomationRun(999, "", "", 1, 1, runTestNow); !errors.Is(err, ErrAutomationRunNotFound) {
		t.Errorf("claim of a missing run: %v; want ErrAutomationRunNotFound", err)
	}
}

func TestAuto05_ConcurrencyN(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "fan", 3)
	var runs []int64
	for _, tr := range []string{TriggerManual, TriggerButton, TriggerSchedule, TriggerCatchUp} {
		id, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: tr})
		runs = append(runs, id)
	}
	for i, id := range runs {
		if got, want := mustClaimAutomationRun(t, d, id), i < 3; got != want {
			t.Errorf("claim %d = %v; want %v", i, got, want)
		}
	}
}

func TestAuto05_ConcurrentClaimsOneWinner(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	a := seedRunAutomation(t, d, "race", 4)
	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})

	const racers = 8
	handles := make([]*DB, racers)
	for i := range handles {
		h, err := OpenExistingRW(path, 10*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = h.Close() })
		handles[i] = h
	}
	var (
		wg    sync.WaitGroup
		start = make(chan struct{})
		wins  = make([]bool, racers)
		errs  = make([]error, racers)
	)
	for i := range handles {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			wins[i], errs[i] = handles[i].ClaimAutomationRun(run, "hash", "snap", 50000, 5, runTestNow)
		}(i)
	}
	close(start)
	wg.Wait()
	winners := 0
	for i := range wins {
		if errs[i] != nil {
			t.Errorf("racer %d: %v", i, errs[i])
		}
		if wins[i] {
			winners++
		}
	}
	if winners != 1 {
		t.Errorf("winners = %d; want exactly 1", winners)
	}
	if r := mustGetAutomationRun(t, d, run); r.Status != RunRunning {
		t.Errorf("status = %s; want running", r.Status)
	}
}

func TestAuto04_FinishCommitOnlyOnSuccess(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	// A prior succeeded run left state and one output.
	prior, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, prior)
	if err := d.FinishAutomationRun(prior, RunFinish{Status: RunSucceeded, Now: runTestNow},
		&RunCommit{StateJSON: json.RawMessage(`{"seen":1}`), Outputs: []AutomationOutput{{Kind: "inbox", Title: "old", Body: "b"}}}); err != nil {
		t.Fatal(err)
	}
	stateBefore, _ := d.GetAutomationState(a)
	outputsBefore, _ := d.ListAutomationOutputs("", 0)

	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, run)
	commit := &RunCommit{StateJSON: json.RawMessage(`{"seen":2}`),
		Outputs: []AutomationOutput{{Kind: "inbox", Title: "new", Body: "b", Priority: "high"}, {Kind: "report", Title: "r", Body: "x"}}}
	err := d.FinishAutomationRun(run, RunFinish{Status: RunFailed, ErrorKind: ErrKindScript, Now: runTestNow}, commit)
	if !errors.Is(err, ErrCommitOnFailure) {
		t.Fatalf("failed+commit: %v; want ErrCommitOnFailure", err)
	}
	stateAfter, _ := d.GetAutomationState(a)
	outputsAfter, _ := d.ListAutomationOutputs("", 0)
	if string(stateAfter) != string(stateBefore) || len(outputsAfter) != len(outputsBefore) {
		t.Errorf("failed commit changed state %s→%s or outputs %d→%d", stateBefore, stateAfter, len(outputsBefore), len(outputsAfter))
	}
	if r := mustGetAutomationRun(t, d, run); r.Status != RunRunning {
		t.Errorf("status = %s; want still running", r.Status)
	}

	if err := d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Summary: "done", Now: runTestNow}, commit); err != nil {
		t.Fatal(err)
	}
	if s, _ := d.GetAutomationState(a); string(s) != `{"seen":2}` {
		t.Errorf("state = %s; want replaced", s)
	}
	outs, _ := d.ListAutomationOutputs("", 0)
	if len(outs) != 3 {
		t.Fatalf("outputs = %d; want 3", len(outs))
	}
	inbox, _ := d.ListAutomationOutputs("inbox", 1)
	if len(inbox) != 1 || inbox[0].Title != "new" || inbox[0].Priority != "high" || inbox[0].RunID != run || inbox[0].AutomationID != a {
		t.Errorf("newest inbox = %+v", inbox)
	}
	if reports, _ := d.ListAutomationOutputs("report", 0); len(reports) != 1 || reports[0].Priority != "medium" {
		t.Errorf("reports = %+v; want one with priority medium", reports)
	}
	r := mustGetAutomationRun(t, d, run)
	if r.Status != RunSucceeded || r.Summary != "done" || r.FinishedAt == nil {
		t.Errorf("finished run = %+v", r)
	}
}

func TestFinish_RefusesTerminalRun(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, run)
	if ok, err := d.CancelAutomationRun(run, runTestNow); err != nil || !ok {
		t.Fatalf("CancelAutomationRun = (%v, %v)", ok, err)
	}
	if ok, err := d.CancelAutomationRun(run, runTestNow); err != nil || ok {
		t.Errorf("second cancel = (%v, %v); want (false, nil)", ok, err)
	}
	err := d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Now: runTestNow},
		&RunCommit{StateJSON: json.RawMessage(`{"x":1}`), Outputs: []AutomationOutput{{Kind: "inbox", Title: "t", Body: "b"}}})
	if !errors.Is(err, ErrRunNotActive) {
		t.Fatalf("finish after cancel: %v; want ErrRunNotActive", err)
	}
	if s, _ := d.GetAutomationState(a); string(s) != `{}` {
		t.Errorf("state = %s; want {}", s)
	}
	if n := countAutomationTableRows(t, d, "automation_outputs"); n != 0 {
		t.Errorf("outputs = %d; want 0", n)
	}
	r := mustGetAutomationRun(t, d, run)
	if r.Status != RunCancelled || r.ErrorKind != ErrKindCancelled {
		t.Errorf("run = %s/%s; want cancelled/cancelled", r.Status, r.ErrorKind)
	}
	if err := d.FinishAutomationRun(999, RunFinish{Status: RunFailed, Now: runTestNow}, nil); !errors.Is(err, ErrAutomationRunNotFound) {
		t.Errorf("finish of a missing run: %v; want ErrAutomationRunNotFound", err)
	}
	if err := d.FinishAutomationRun(run, RunFinish{Status: RunRunning, Now: runTestNow}, nil); err == nil {
		t.Error("finish with a non-terminal status accepted")
	}
}

func TestCancelQueuedNotRunnable(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	if err := d.CancelQueuedNotRunnable(run, runTestNow); err != nil {
		t.Fatal(err)
	}
	if r := mustGetAutomationRun(t, d, run); r.Status != RunCancelled || r.ErrorKind != ErrKindNotRunnable {
		t.Errorf("run = %s/%s; want cancelled/not_runnable", r.Status, r.ErrorKind)
	}
	if err := d.CancelQueuedNotRunnable(run, runTestNow); !errors.Is(err, ErrRunNotQueued) {
		t.Errorf("second cancel: %v; want ErrRunNotQueued", err)
	}
}

func TestAuto08_RestartMarksInterrupted(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 4)
	running, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	waiting, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerButton})
	queued, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule})
	mustClaimAutomationRun(t, d, running)
	mustClaimAutomationRun(t, d, waiting)
	if err := d.SetAutomationRunWaiting(waiting, WaitAsk); err != nil {
		t.Fatal(err)
	}
	active, err := d.ListActiveAutomationRuns()
	if err != nil || len(active) != 2 {
		t.Fatalf("active = %d, %v; want 2", len(active), err)
	}
	n, err := d.MarkInterruptedAutomationRuns(runTestNow)
	if err != nil || n != 2 {
		t.Fatalf("MarkInterruptedAutomationRuns = (%d, %v); want 2", n, err)
	}
	for _, id := range []int64{running, waiting} {
		r := mustGetAutomationRun(t, d, id)
		if r.Status != RunFailed || r.ErrorKind != ErrKindInterrupted || r.WaitingReason != "" || r.FinishedAt == nil {
			t.Errorf("run %d = %s/%s/%q", id, r.Status, r.ErrorKind, r.WaitingReason)
		}
	}
	if r := mustGetAutomationRun(t, d, queued); r.Status != RunQueued {
		t.Errorf("queued run = %s; want queued", r.Status)
	}
	if next, _ := d.NextQueuedAutomationRuns(10); len(next) != 1 || next[0].ID != queued {
		t.Errorf("next queued = %+v", next)
	}
}

func TestRunWaiting_ReasonChangeWhileWaiting(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, run)
	if err := d.AddAutomationRunUsage(run, RunUsage{ActiveMS: 1500}); err != nil {
		t.Fatal(err)
	}
	if err := d.SetAutomationRunWaiting(run, WaitApp); err != nil {
		t.Fatal(err)
	}
	if err := d.SetAutomationRunWaiting(run, WaitSession); err != nil {
		t.Fatal(err)
	}
	r := mustGetAutomationRun(t, d, run)
	if r.Status != RunWaiting || r.WaitingReason != WaitSession || r.ActiveMS != 1500 {
		t.Errorf("run = %s/%q/%d; want waiting/session/1500", r.Status, r.WaitingReason, r.ActiveMS)
	}
	if err := d.SetAutomationRunWaiting(run, WaitNone); err == nil {
		t.Error("empty waiting reason accepted")
	}
	if err := d.ResumeAutomationRun(run); err != nil {
		t.Fatal(err)
	}
	if r := mustGetAutomationRun(t, d, run); r.Status != RunRunning || r.WaitingReason != "" {
		t.Errorf("resumed = %s/%q", r.Status, r.WaitingReason)
	}
	if err := d.ResumeAutomationRun(run); !errors.Is(err, ErrRunNotActive) {
		t.Errorf("resume of a running run: %v; want ErrRunNotActive", err)
	}
	if err := d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Now: runTestNow}, nil); err != nil {
		t.Fatal(err)
	}
	if err := d.SetAutomationRunWaiting(run, WaitSession); !errors.Is(err, ErrRunNotActive) {
		t.Errorf("waiting on a succeeded run: %v; want ErrRunNotActive", err)
	}
	if err := d.SetAutomationRunWaiting(999, WaitAsk); !errors.Is(err, ErrAutomationRunNotFound) {
		t.Errorf("waiting on a missing run: %v; want ErrAutomationRunNotFound", err)
	}
}

func seedRunningAutomationRun(t *testing.T, d *DB) int64 {
	t.Helper()
	a := seedRunAutomation(t, d, "digest", 1)
	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, run)
	return run
}

func TestSteps_MarkIsNonFinal(t *testing.T) {
	d := openTestDB(t)
	run := seedRunningAutomationRun(t, d)
	id, err := d.AppendAutomationRunStep(AutomationRunStep{RunID: run, Kind: "tool", Name: "create_jira_issue",
		Status: "proposed", StartedAt: runTestNow})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.MarkAutomationRunStep(id, "waiting", StepFinish{ActionID: 7}); err != nil {
		t.Fatal(err)
	}
	steps, _ := d.ListAutomationRunSteps(run)
	if s := steps[0]; s.Status != "waiting" || s.ActionID != 7 || s.FinishedAt != nil || s.AskID != 0 {
		t.Errorf("marked step = %+v", s)
	}
	if err := d.FinishAutomationRunStep(id, StepFinish{Status: "applied", ResultSummary: "ok", Now: runTestNow}); err != nil {
		t.Fatal(err)
	}
	steps, _ = d.ListAutomationRunSteps(run)
	if s := steps[0]; s.Status != "applied" || s.ActionID != 7 || s.FinishedAt == nil || s.ResultSummary != "ok" {
		t.Errorf("finished step = %+v; action_id kept, finished_at set", s)
	}
	if err := d.MarkAutomationRunStep(id, "waiting", StepFinish{}); !errors.Is(err, ErrStepFinished) {
		t.Errorf("mark after finish: %v; want ErrStepFinished", err)
	}
	if err := d.FinishAutomationRunStep(id, StepFinish{Status: "ok", Now: runTestNow}); !errors.Is(err, ErrStepFinished) {
		t.Errorf("second finish: %v; want ErrStepFinished", err)
	}
	if err := d.MarkAutomationRunStep(999, "waiting", StepFinish{}); !errors.Is(err, ErrAutomationRunStepNotFound) {
		t.Errorf("mark of a missing step: %v; want ErrAutomationRunStepNotFound", err)
	}
}

func TestSteps_SeqIsDenseAndOrdered(t *testing.T) {
	d := openTestDB(t)
	run := seedRunningAutomationRun(t, d)
	var ids []int64
	for _, kind := range []string{"llm", "tool", "log"} {
		id, err := d.AppendAutomationRunStep(AutomationRunStep{RunID: run, Kind: kind, Status: "ok", StartedAt: runTestNow})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	cost := 0.02
	if err := d.FinishAutomationRunStep(ids[0], StepFinish{Status: "ok", InputTokens: 120, OutputTokens: 30,
		TokensEstimated: true, ReportedCostUSD: &cost, DurationMS: 900, Now: runTestNow}); err != nil {
		t.Fatal(err)
	}
	steps, err := d.ListAutomationRunSteps(run)
	if err != nil || len(steps) != 3 {
		t.Fatalf("steps = %d, %v", len(steps), err)
	}
	for i, s := range steps {
		if s.Seq != i+1 || s.ID != ids[i] {
			t.Errorf("step %d seq = %d id = %d; want %d/%d", i, s.Seq, s.ID, i+1, ids[i])
		}
	}
	if s := steps[0]; s.InputTokens != 120 || s.OutputTokens != 30 || !s.TokensEstimated || s.DurationMS != 900 ||
		s.ReportedCostUSD == nil || *s.ReportedCostUSD != cost {
		t.Errorf("finished llm step = %+v", s)
	}
	if empty, err := d.ListAutomationRunSteps(999); err != nil || empty == nil || len(empty) != 0 {
		t.Errorf("steps of a missing run = %v, %v; want empty non-nil", empty, err)
	}
	if _, err := d.AppendAutomationRunStep(AutomationRunStep{RunID: run, Kind: "llm", Status: "ok"}); err == nil {
		t.Error("step with zero StartedAt accepted")
	}
}

func TestEventPayload_MarshalsEmptyArrays(t *testing.T) {
	b, err := json.Marshal(AutomationEventPayload{})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(b), `{"cycles":[],"events":[],"count":0,"truncated":false}`; got != want {
		t.Errorf("payload = %s; want %s", got, want)
	}
	full := AutomationEventPayload{Cycles: []string{"c1"}, Events: []json.RawMessage{json.RawMessage(`{"channel":"releases"}`)}, Count: 3, Truncated: true}
	b, _ = json.Marshal(full)
	var back AutomationEventPayload
	if err := json.Unmarshal(b, &back); err != nil || back.Count != 3 || !back.Truncated || len(back.Events) != 1 || back.Cycles[0] != "c1" {
		t.Errorf("round trip = %+v, %v", back, err)
	}
}

func TestAutomationTokensBetween_LocalDayWindow(t *testing.T) {
	d := openTestDB(t)
	loc := time.FixedZone("acme", 2*3600)
	day1 := time.Date(2026, 3, 10, 0, 0, 0, 0, loc)
	day2, day3 := day1.AddDate(0, 0, 1), day1.AddDate(0, 0, 2)
	a := seedRunAutomation(t, d, "digest", 4)
	for i, started := range []time.Time{day2.Add(-time.Minute), day2.Add(time.Minute)} {
		tr := []string{TriggerManual, TriggerButton}[i]
		run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: tr})
		if ok, err := d.ClaimAutomationRun(run, "h", "s", 50000, 5, started); err != nil || !ok {
			t.Fatalf("claim = (%v, %v)", ok, err)
		}
		if err := d.AddAutomationRunUsage(run, RunUsage{InputTokens: int64(100 * (i + 1)), OutputTokens: 10}); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := d.AutomationTokensBetween(day1, day2); err != nil || n != 110 {
		t.Errorf("day 1 = %d, %v; want 110 (the 23:59 run)", n, err)
	}
	if n, err := d.AutomationTokensBetween(day2, day3); err != nil || n != 210 {
		t.Errorf("day 2 = %d, %v; want 210 (the 00:01 run)", n, err)
	}
	if n, err := d.AutomationTokensBetween(day3, day3.AddDate(0, 0, 1)); err != nil || n != 0 {
		t.Errorf("empty day = %d, %v; want 0", n, err)
	}
}

func TestAddAutomationRunUsage_Accumulates(t *testing.T) {
	d := openTestDB(t)
	run := seedRunningAutomationRun(t, d)
	cost := 0.5
	for _, u := range []RunUsage{
		{InputTokens: 10, OutputTokens: 5},
		{InputTokens: 1, OutputTokens: 1, Estimated: true, ReportedCostUSD: &cost, ActiveMS: 40},
		{InputTokens: 1, ReportedCostUSD: &cost},
	} {
		if err := d.AddAutomationRunUsage(run, u); err != nil {
			t.Fatal(err)
		}
	}
	r := mustGetAutomationRun(t, d, run)
	if r.InputTokens != 12 || r.OutputTokens != 6 || !r.TokensEstimated || r.ActiveMS != 40 ||
		r.ReportedCostUSD == nil || *r.ReportedCostUSD != 1.0 {
		t.Errorf("usage = %+v", r)
	}
	if err := d.AddAutomationRunUsage(999, RunUsage{}); !errors.Is(err, ErrAutomationRunNotFound) {
		t.Errorf("usage on a missing run: %v; want ErrAutomationRunNotFound", err)
	}
	other := seedRunAutomation(t, d, "other", 1)
	fresh, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: other, Trigger: TriggerManual})
	if r := mustGetAutomationRun(t, d, fresh); r.ReportedCostUSD != nil {
		t.Errorf("unreported cost = %v; want nil", *r.ReportedCostUSD)
	}
	if runs, err := d.ListAutomationRuns(other, 0); err != nil || len(runs) != 1 {
		t.Errorf("ListAutomationRuns = %d, %v", len(runs), err)
	}
	if runs, err := d.ListAutomationRuns(12345, 5); err != nil || runs == nil || len(runs) != 0 {
		t.Errorf("runs of a missing automation = %v, %v; want empty non-nil", runs, err)
	}
}
