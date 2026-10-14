package db

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
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

// wantAutomationRun checks a run's status and error kind.
func wantAutomationRun(t *testing.T, d *DB, id int64, status, errorKind string) *AutomationRun {
	t.Helper()
	r := mustGetAutomationRun(t, d, id)
	if r.Status != status || r.ErrorKind != errorKind {
		t.Errorf("run %d = %s/%q; want %s/%q", id, r.Status, r.ErrorKind, status, errorKind)
	}
	return r
}

// wantCoalesced checks an enqueue result.
func wantCoalesced(t *testing.T, what string, gotID int64, gotCoalesced bool, wantID int64) {
	t.Helper()
	if gotID != wantID || !gotCoalesced {
		t.Errorf("%s = (%d, %v); want (%d, true)", what, gotID, gotCoalesced, wantID)
	}
}

func wantRowCount(t *testing.T, d *DB, table string, want int) {
	t.Helper()
	if n := countAutomationTableRows(t, d, table); n != want {
		t.Errorf("%s rows = %d; want %d", table, n, want)
	}
}

func wantErrIs(t *testing.T, what string, err, target error) {
	t.Helper()
	if !errors.Is(err, target) {
		t.Errorf("%s: %v; want %v", what, err, target)
	}
}

// automationData is the committed state bytes and every output of an automation.
type automationData struct {
	state   string
	outputs []AutomationOutput
}

func readAutomationData(t *testing.T, d *DB, automationID int64) automationData {
	t.Helper()
	s, err := d.GetAutomationState(automationID)
	if err != nil {
		t.Fatalf("GetAutomationState: %v", err)
	}
	outs, err := d.ListAutomationOutputs("", 0)
	if err != nil {
		t.Fatalf("ListAutomationOutputs: %v", err)
	}
	return automationData{state: string(s), outputs: outs}
}

func wantAutomationDataUnchanged(t *testing.T, d *DB, automationID int64, before automationData) {
	t.Helper()
	if after := readAutomationData(t, d, automationID); !reflect.DeepEqual(after, before) {
		t.Errorf("state/outputs changed:\n before %+v\n after  %+v", before, after)
	}
}

func seedRunningAutomationRun(t *testing.T, d *DB) (automationID, runID int64) {
	t.Helper()
	a := seedRunAutomation(t, d, "digest", 1)
	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	if !mustClaimAutomationRun(t, d, run) {
		t.Fatal("claim lost")
	}
	return a, run
}

func mustFinishAutomationRun(t *testing.T, d *DB, runID int64, f RunFinish, c *RunCommit) {
	t.Helper()
	if f.Now.IsZero() {
		f.Now = runTestNow
	}
	if err := d.FinishAutomationRun(runID, f, c); err != nil {
		t.Fatalf("FinishAutomationRun(%d): %v", runID, err)
	}
}

func mustAppendAutomationRunStep(t *testing.T, d *DB, runID int64, kind, status string) int64 {
	t.Helper()
	id, err := d.AppendAutomationRunStep(AutomationRunStep{RunID: runID, Kind: kind, Status: status, StartedAt: runTestNow})
	if err != nil {
		t.Fatalf("AppendAutomationRunStep: %v", err)
	}
	return id
}

func sameAutomationTime(got *time.Time, want time.Time) bool {
	return got != nil && got.Equal(want)
}

func TestEnqueue_InsertsQueued(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	id, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	if coalesced {
		t.Error("first enqueue coalesced")
	}
	r := wantAutomationRun(t, d, id, RunQueued, "")
	if !r.QueuedAt.Equal(runTestNow) || r.Trigger != TriggerManual || r.StartedAt != nil {
		t.Errorf("run = %+v; want queued at %v", r, runTestNow)
	}
}

func TestRun_CoalescesSecondTrigger(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	first, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	second, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	wantCoalesced(t, "second manual", second, coalesced, first)
	button, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerButton})
	if button == first || coalesced {
		t.Errorf("button = (%d, %v); want a new row", button, coalesced)
	}
	wantRowCount(t, d, "automation_runs", 2)
}

func TestEnqueue_EventCycleOncePerAutomation(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "watch", 1)
	first, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerEvent, EventCycle: "c1",
		EventJSON: `{"cycles":["c1"],"events":[],"count":0,"truncated":false}`})
	if !mustClaimAutomationRun(t, d, first) {
		t.Fatal("claim failed")
	}
	mustFinishAutomationRun(t, d, first, RunFinish{Status: RunSucceeded}, nil)
	again, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerEvent, EventCycle: "c1"})
	wantCoalesced(t, "same cycle after finish", again, coalesced, first)
	wantRowCount(t, d, "automation_runs", 1)
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
	wantCoalesced(t, "cycle B", id, coalesced, seeded)
	wantRowCount(t, d, "automation_runs", 1)
	// A malformed event_json of another event run never breaks the lookup, and
	// a non-event run's event_json is not consulted.
	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, event_json, status)
		VALUES (?, 'event', '{', 'failed'), (?, 'manual', '{"cycles":["C"]}', 'failed')`, a, a); err != nil {
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
		wantCoalesced(t, "cycle "+cycle, id, coalesced, queued)
	}
	if r := mustGetAutomationRun(t, d, queued); r.EventCycle != "A" {
		t.Errorf("event_cycle = %q; want A untouched", r.EventCycle)
	}
	wantRowCount(t, d, "automation_runs", 1)
}

func TestEnqueue_AdvancesScheduleAtomically(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "daily", 1)
	due1, due2 := runTestNow.Add(-time.Hour), runTestNow
	next := runTestNow.Add(24 * time.Hour)
	mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule, ScheduledFor: &due1,
		AdvanceScheduleTo: &due1, NextRunAt: &due2, ExpectLastScheduledFor: mustGetAutomation(t, d, a).LastScheduledFor})
	_, coalesced := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule, ScheduledFor: &due2,
		AdvanceScheduleTo: &due2, NextRunAt: &next, ExpectLastScheduledFor: &due1})
	if !coalesced {
		t.Fatal("second schedule enqueue not coalesced")
	}
	got := mustGetAutomation(t, d, a)
	if !sameAutomationTime(got.LastScheduledFor, due2) || !sameAutomationTime(got.NextRunAt, next) {
		t.Errorf("schedule = (%v, %v); want (%v, %v)", got.LastScheduledFor, got.NextRunAt, due2, next)
	}
	_, _, err := d.EnqueueAutomationRun(EnqueueRequest{AutomationID: 999, Trigger: TriggerSchedule,
		AdvanceScheduleTo: &due2, Now: runTestNow})
	if err == nil {
		t.Error("enqueue for a missing automation succeeded")
	}
}

func TestEnqueue_ScheduleCompareAndSet(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "daily", 1)
	read := runTestNow.Add(-2 * time.Hour)
	moved := runTestNow.Add(-time.Minute) // a confirm stamped it after the read
	if err := d.SetAutomationSchedule(a, &moved, nil); err != nil {
		t.Fatal(err)
	}
	due := runTestNow
	_, _, err := d.EnqueueAutomationRun(EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule, ScheduledFor: &due,
		AdvanceScheduleTo: &due, ExpectLastScheduledFor: &read, Now: runTestNow})
	if !errors.Is(err, ErrScheduleChanged) {
		t.Fatalf("enqueue with a stale schedule point = %v, want ErrScheduleChanged", err)
	}
	wantRowCount(t, d, "automation_runs", 0)
	if got := mustGetAutomation(t, d, a); !sameAutomationTime(got.LastScheduledFor, moved) {
		t.Errorf("last_scheduled_for = %v, want %v untouched", got.LastScheduledFor, moved)
	}
	// An expected NULL does not match a set value either.
	_, _, err = d.EnqueueAutomationRun(EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule, ScheduledFor: &due,
		AdvanceScheduleTo: &due, Now: runTestNow})
	if !errors.Is(err, ErrScheduleChanged) {
		t.Fatalf("enqueue expecting NULL = %v, want ErrScheduleChanged", err)
	}
	wantRowCount(t, d, "automation_runs", 0)
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
	mustFinishAutomationRun(t, d, r1, RunFinish{Status: RunSucceeded}, nil)
	if !mustClaimAutomationRun(t, d, r2) {
		t.Fatal("second claim lost after the first finished")
	}
	r := wantAutomationRun(t, d, r2, RunRunning, "")
	got := []any{r.RecipeHash, r.RecipeSnapshot, r.BudgetTokens, r.BudgetMinutes, r.StartedAt != nil}
	if want := []any{"hash", "snapshot", 50000, 5, true}; !reflect.DeepEqual(got, want) {
		t.Errorf("claim snapshot = %v; want %v", got, want)
	}
	if mustClaimAutomationRun(t, d, r2) {
		t.Error("a running run was claimed again")
	}
	_, err := d.ClaimAutomationRun(999, "", "", 1, 1, runTestNow)
	wantErrIs(t, "claim of a missing run", err, ErrAutomationRunNotFound)
}

func TestAuto05_ConcurrencyN(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "fan", 3)
	for i, tr := range []string{TriggerManual, TriggerButton, TriggerSchedule, TriggerCatchUp} {
		id, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: tr})
		if got, want := mustClaimAutomationRun(t, d, id), i < 3; got != want {
			t.Errorf("claim %d = %v; want %v", i, got, want)
		}
	}
}

// openClaimRacers opens n extra connections to the file DB at path, one per
// racer, so the claims race across connections as two processes would.
func openClaimRacers(t *testing.T, path string, n int) []*DB {
	t.Helper()
	handles := make([]*DB, n)
	for i := range handles {
		h, err := OpenExistingRW(path, 10*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = h.Close() })
		handles[i] = h
	}
	return handles
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

	handles := openClaimRacers(t, path, 8)
	var (
		wg    sync.WaitGroup
		start = make(chan struct{})
		wins  = make([]bool, len(handles))
		errs  = make([]error, len(handles))
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
	wantAutomationRun(t, d, run, RunRunning, "")
}

func TestAuto04_FinishCommitOnlyOnSuccess(t *testing.T) {
	d := openTestDB(t)
	a, prior := seedRunningAutomationRun(t, d)
	// A prior succeeded run left state and one output.
	mustFinishAutomationRun(t, d, prior, RunFinish{Status: RunSucceeded},
		&RunCommit{StateJSON: json.RawMessage(`{"seen":1}`), Outputs: []AutomationOutput{{Kind: "inbox", Title: "old", Body: "b"}}})
	before := readAutomationData(t, d, a)

	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, run)
	commit := &RunCommit{StateJSON: json.RawMessage(`{"seen":2}`),
		Outputs: []AutomationOutput{{Kind: "inbox", Title: "new", Body: "b", Priority: "high"}, {Kind: "report", Title: "r", Body: "x"}}}

	err := d.FinishAutomationRun(run, RunFinish{Status: RunFailed, ErrorKind: ErrKindScript, Now: runTestNow}, commit)
	wantErrIs(t, "failed+commit", err, ErrCommitOnFailure)
	wantAutomationDataUnchanged(t, d, a, before)
	wantAutomationRun(t, d, run, RunRunning, "")

	// One transaction: an output write that fails after the state write rolls
	// the state, the earlier output and the run's own status back.
	broken := &RunCommit{StateJSON: json.RawMessage(`{"seen":99}`),
		Outputs: []AutomationOutput{{Kind: "inbox", Title: "first", Body: "b"}, {Kind: "bogus", Title: "t", Body: "b"}}}
	if err := d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Now: runTestNow}, broken); err == nil {
		t.Fatal("finish with a CHECK-violating output kind succeeded")
	}
	wantAutomationDataUnchanged(t, d, a, before)
	wantAutomationRun(t, d, run, RunRunning, "")

	mustFinishAutomationRun(t, d, run, RunFinish{Status: RunSucceeded, Summary: "done"}, commit)
	wantCommittedRun(t, d, a, run)
}

// wantCommittedRun checks what TestAuto04_FinishCommitOnlyOnSuccess's
// succeeded finish committed.
func wantCommittedRun(t *testing.T, d *DB, a, run int64) {
	t.Helper()
	data := readAutomationData(t, d, a)
	if data.state != `{"seen":2}` || len(data.outputs) != 3 {
		t.Fatalf("after success: state %s, %d outputs; want {\"seen\":2} and 3", data.state, len(data.outputs))
	}
	inbox, err := d.ListAutomationOutputs("inbox", 1)
	if err != nil || len(inbox) != 1 {
		t.Fatalf("inbox outputs = %d, %v; want 1", len(inbox), err)
	}
	got := []any{inbox[0].Title, inbox[0].Priority, inbox[0].RunID, inbox[0].AutomationID}
	if want := []any{"new", "high", run, a}; !reflect.DeepEqual(got, want) {
		t.Errorf("newest inbox = %v; want %v", got, want)
	}
	reports, err := d.ListAutomationOutputs("report", 0)
	if err != nil || len(reports) != 1 || reports[0].Priority != "medium" {
		t.Errorf("reports = %+v, %v; want one with priority medium", reports, err)
	}
	r := wantAutomationRun(t, d, run, RunSucceeded, "")
	if r.Summary != "done" || r.FinishedAt == nil {
		t.Errorf("finished run = %+v", r)
	}
}

func TestFinish_RefusesForeignOutput(t *testing.T) {
	d := openTestDB(t)
	a, run := seedRunningAutomationRun(t, d)
	other := seedRunAutomation(t, d, "other", 1)
	before := readAutomationData(t, d, a)
	for name, o := range map[string]AutomationOutput{
		"foreign automation": {AutomationID: other, Kind: "inbox", Title: "t", Body: "b"},
		"foreign run":        {RunID: run + 100, Kind: "inbox", Title: "t", Body: "b"},
	} {
		c := &RunCommit{StateJSON: json.RawMessage(`{"x":1}`), Outputs: []AutomationOutput{{Kind: "report", Title: "ok", Body: "b"}, o}}
		if err := d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Now: runTestNow}, c); err == nil {
			t.Errorf("%s: finish succeeded; want refused", name)
		}
		wantAutomationDataUnchanged(t, d, a, before)
		wantAutomationRun(t, d, run, RunRunning, "")
	}
	ok := &RunCommit{Outputs: []AutomationOutput{{AutomationID: a, RunID: run, Kind: "inbox", Title: "own", Body: "b"}}}
	mustFinishAutomationRun(t, d, run, RunFinish{Status: RunSucceeded}, ok)
	wantRowCount(t, d, "automation_outputs", 1)
}

func TestFinish_RefusesTerminalRun(t *testing.T) {
	d := openTestDB(t)
	a, run := seedRunningAutomationRun(t, d)
	if ok, err := d.CancelAutomationRun(run, runTestNow); err != nil || !ok {
		t.Fatalf("CancelAutomationRun = (%v, %v)", ok, err)
	}
	if ok, err := d.CancelAutomationRun(run, runTestNow); err != nil || ok {
		t.Errorf("second cancel = (%v, %v); want (false, nil)", ok, err)
	}
	before := readAutomationData(t, d, a)
	err := d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Now: runTestNow},
		&RunCommit{StateJSON: json.RawMessage(`{"x":1}`), Outputs: []AutomationOutput{{Kind: "inbox", Title: "t", Body: "b"}}})
	wantErrIs(t, "finish after cancel", err, ErrRunNotActive)
	wantAutomationDataUnchanged(t, d, a, before)
	if before.state != `{}` {
		t.Errorf("state = %s; want {}", before.state)
	}
	wantAutomationRun(t, d, run, RunCancelled, ErrKindCancelled)
	err = d.FinishAutomationRun(999, RunFinish{Status: RunFailed, Now: runTestNow}, nil)
	wantErrIs(t, "finish of a missing run", err, ErrAutomationRunNotFound)
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
	wantAutomationRun(t, d, run, RunCancelled, ErrKindNotRunnable)
	wantErrIs(t, "second cancel", d.CancelQueuedNotRunnable(run, runTestNow), ErrRunNotQueued)
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
	if active, err := d.ListActiveAutomationRuns(); err != nil || len(active) != 2 {
		t.Fatalf("active = %d, %v; want 2", len(active), err)
	}
	if n, err := d.MarkInterruptedAutomationRuns(runTestNow); err != nil || n != 2 {
		t.Fatalf("MarkInterruptedAutomationRuns = (%d, %v); want 2", n, err)
	}
	for _, id := range []int64{running, waiting} {
		r := wantAutomationRun(t, d, id, RunFailed, ErrKindInterrupted)
		if r.WaitingReason != "" || r.FinishedAt == nil {
			t.Errorf("run %d reason %q finished_at %v", id, r.WaitingReason, r.FinishedAt)
		}
	}
	wantAutomationRun(t, d, queued, RunQueued, "")
	if next, err := d.NextQueuedAutomationRuns(10); err != nil || len(next) != 1 || next[0].ID != queued {
		t.Errorf("next queued = %+v, %v", next, err)
	}
}

// claimDryRunAt queues and claims a dry run of automation a started at started
// with a budget of budgetMinutes snapshotted on the run.
func claimDryRunAt(t *testing.T, d *DB, a int64, started time.Time, budgetMinutes int) int64 {
	t.Helper()
	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerDryRun})
	if ok, err := d.ClaimAutomationRun(run, "h", "s", 50000, budgetMinutes, started); err != nil || !ok {
		t.Fatalf("claim dry run = (%v, %v)", ok, err)
	}
	return run
}

func TestAuto08_RestartSparesLiveDryRun(t *testing.T) {
	d := openTestDB(t)
	// budget 5 minutes + 1 minute grace = a 6-minute deadline.
	live := claimDryRunAt(t, d, seedRunAutomation(t, d, "live", 1), runTestNow.Add(-2*time.Minute), 5)
	stale := claimDryRunAt(t, d, seedRunAutomation(t, d, "stale", 1), runTestNow.Add(-7*time.Minute), 5)
	// budget_minutes 0 on the run falls back to the automation's 5, so a run
	// started 3 minutes ago is still live (with 0 it would be past 0 + 1).
	fallback := claimDryRunAt(t, d, seedRunAutomation(t, d, "fallback", 1), runTestNow.Add(-3*time.Minute), 0)
	if n, err := d.MarkInterruptedAutomationRuns(runTestNow); err != nil || n != 1 {
		t.Fatalf("MarkInterruptedAutomationRuns = (%d, %v); want 1", n, err)
	}
	wantAutomationRun(t, d, live, RunRunning, "")
	wantAutomationRun(t, d, stale, RunFailed, ErrKindInterrupted)
	wantAutomationRun(t, d, fallback, RunRunning, "")
}

func TestNextQueued_SkipsDryRun(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	dry, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerDryRun})
	manual, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	next, err := d.NextQueuedAutomationRuns(0)
	if err != nil || len(next) != 1 || next[0].ID != manual {
		t.Errorf("next queued = %+v, %v; want only the manual run %d", next, err, manual)
	}
	if !mustClaimAutomationRun(t, d, dry) {
		t.Error("the CLI could not claim its dry run by id")
	}
}

// TestRunEnd_ClosesOpenSteps: every way a run ends closes its open steps in
// the same transaction.
func TestRunEnd_ClosesOpenSteps(t *testing.T) {
	for name, end := range map[string]func(d *DB, run int64) error{
		"cancel": func(d *DB, run int64) error { _, err := d.CancelAutomationRun(run, runTestNow); return err },
		"expire": func(d *DB, run int64) error {
			return d.FinishAutomationRun(run, RunFinish{Status: RunExpired, ErrorKind: ErrKindExpired, Now: runTestNow}, nil)
		},
		"interrupt": func(d *DB, _ int64) error { _, err := d.MarkInterruptedAutomationRuns(runTestNow); return err },
	} {
		t.Run(name, func(t *testing.T) {
			d := openTestDB(t)
			_, run := seedRunningAutomationRun(t, d)
			done := mustAppendAutomationRunStep(t, d, run, "llm", "ok")
			if err := d.FinishAutomationRunStep(done, StepFinish{Status: "ok", Now: runTestNow}); err != nil {
				t.Fatal(err)
			}
			mustAppendAutomationRunStep(t, d, run, "tool", "proposed")
			if err := end(d, run); err != nil {
				t.Fatal(err)
			}
			wantStepsClosed(t, d, run, []string{"ok", "error"})
		})
	}
}

func wantStepsClosed(t *testing.T, d *DB, run int64, statuses []string) {
	t.Helper()
	steps, err := d.ListAutomationRunSteps(run)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, s := range steps {
		got = append(got, s.Status)
		if s.FinishedAt == nil {
			t.Errorf("step %d still open", s.Seq)
		}
	}
	if !reflect.DeepEqual(got, statuses) {
		t.Errorf("step statuses = %v; want %v", got, statuses)
	}
}

// TestRunWriters_RefuseZeroTime: every writer that stamps a time refuses a
// zero one before writing.
func TestRunWriters_RefuseZeroTime(t *testing.T) {
	d := openTestDB(t)
	a, run := seedRunningAutomationRun(t, d)
	step := mustAppendAutomationRunStep(t, d, run, "llm", "ok")
	queued, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerButton})
	var zero time.Time
	for name, write := range map[string]func() error{
		"enqueue": func() error {
			_, _, err := d.EnqueueAutomationRun(EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule})
			return err
		},
		"claim":         func() error { _, err := d.ClaimAutomationRun(queued, "h", "s", 1, 1, zero); return err },
		"cancel queued": func() error { return d.CancelQueuedNotRunnable(queued, zero) },
		"cancel":        func() error { _, err := d.CancelAutomationRun(run, zero); return err },
		"finish":        func() error { return d.FinishAutomationRun(run, RunFinish{Status: RunFailed}, nil) },
		"interrupt":     func() error { _, err := d.MarkInterruptedAutomationRuns(zero); return err },
		"append step": func() error {
			_, err := d.AppendAutomationRunStep(AutomationRunStep{RunID: run, Kind: "llm", Status: "ok"})
			return err
		},
		"finish step": func() error { return d.FinishAutomationRunStep(step, StepFinish{Status: "ok"}) },
	} {
		if err := write(); err == nil {
			t.Errorf("%s with a zero time accepted", name)
		}
	}
	wantAutomationRun(t, d, run, RunRunning, "")
	wantAutomationRun(t, d, queued, RunQueued, "")
	wantRowCount(t, d, "automation_run_steps", 1)
	wantStepsOpen(t, d, run)
}

func wantStepsOpen(t *testing.T, d *DB, run int64) {
	t.Helper()
	steps, err := d.ListAutomationRunSteps(run)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range steps {
		if s.FinishedAt != nil {
			t.Errorf("step %d finished; want open", s.Seq)
		}
	}
}

func TestRunWaiting_ReasonChangeWhileWaiting(t *testing.T) {
	d := openTestDB(t)
	_, run := seedRunningAutomationRun(t, d)
	if err := d.AddAutomationRunUsage(run, RunUsage{ActiveMS: 1500}); err != nil {
		t.Fatal(err)
	}
	for _, reason := range []string{WaitApp, WaitSession} {
		if err := d.SetAutomationRunWaiting(run, reason); err != nil {
			t.Fatal(err)
		}
	}
	r := wantAutomationRun(t, d, run, RunWaiting, "")
	if r.WaitingReason != WaitSession || r.ActiveMS != 1500 {
		t.Errorf("run reason %q active %d; want session/1500", r.WaitingReason, r.ActiveMS)
	}
	if err := d.SetAutomationRunWaiting(run, WaitNone); err == nil {
		t.Error("empty waiting reason accepted")
	}
	if err := d.ResumeAutomationRun(run); err != nil {
		t.Fatal(err)
	}
	if r := wantAutomationRun(t, d, run, RunRunning, ""); r.WaitingReason != "" {
		t.Errorf("resumed reason = %q", r.WaitingReason)
	}
	wantErrIs(t, "resume of a running run", d.ResumeAutomationRun(run), ErrRunNotActive)
	mustFinishAutomationRun(t, d, run, RunFinish{Status: RunSucceeded}, nil)
	wantErrIs(t, "waiting on a succeeded run", d.SetAutomationRunWaiting(run, WaitSession), ErrRunNotActive)
	wantErrIs(t, "waiting on a missing run", d.SetAutomationRunWaiting(999, WaitAsk), ErrAutomationRunNotFound)
}

func TestSteps_MarkIsNonFinal(t *testing.T) {
	d := openTestDB(t)
	_, run := seedRunningAutomationRun(t, d)
	id := mustAppendAutomationRunStep(t, d, run, "tool", "proposed")
	if err := d.MarkAutomationRunStep(id, "waiting", StepFinish{ActionID: 7}); err != nil {
		t.Fatal(err)
	}
	wantStep(t, d, run, []any{"waiting", int64(7), int64(0), false, ""})
	if err := d.FinishAutomationRunStep(id, StepFinish{Status: "applied", ResultSummary: "ok", Now: runTestNow}); err != nil {
		t.Fatal(err)
	}
	wantStep(t, d, run, []any{"applied", int64(7), int64(0), true, "ok"})
	wantErrIs(t, "mark after finish", d.MarkAutomationRunStep(id, "waiting", StepFinish{}), ErrStepFinished)
	wantErrIs(t, "second finish", d.FinishAutomationRunStep(id, StepFinish{Status: "ok", Now: runTestNow}), ErrStepFinished)
	wantErrIs(t, "mark of a missing step", d.MarkAutomationRunStep(999, "waiting", StepFinish{}), ErrAutomationRunStepNotFound)
}

// wantStep checks the run's only step as [status, action_id, ask_id, finished, result_summary].
func wantStep(t *testing.T, d *DB, run int64, want []any) {
	t.Helper()
	steps, err := d.ListAutomationRunSteps(run)
	if err != nil || len(steps) != 1 {
		t.Fatalf("steps = %d, %v; want 1", len(steps), err)
	}
	s := steps[0]
	if got := []any{s.Status, s.ActionID, s.AskID, s.FinishedAt != nil, s.ResultSummary}; !reflect.DeepEqual(got, want) {
		t.Errorf("step = %v; want %v", got, want)
	}
}

func TestSteps_SeqIsDenseAndOrdered(t *testing.T) {
	d := openTestDB(t)
	_, run := seedRunningAutomationRun(t, d)
	var ids []int64
	for _, kind := range []string{"llm", "tool", "log"} {
		ids = append(ids, mustAppendAutomationRunStep(t, d, run, kind, "ok"))
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
	var gotSeq []int
	var gotIDs []int64
	for _, s := range steps {
		gotSeq, gotIDs = append(gotSeq, s.Seq), append(gotIDs, s.ID)
	}
	if !reflect.DeepEqual(gotSeq, []int{1, 2, 3}) || !reflect.DeepEqual(gotIDs, ids) {
		t.Errorf("seq = %v ids = %v; want [1 2 3] %v", gotSeq, gotIDs, ids)
	}
	s := steps[0]
	got := []any{s.InputTokens, s.OutputTokens, s.TokensEstimated, s.DurationMS, s.ReportedCostUSD != nil && *s.ReportedCostUSD == cost}
	if want := []any{int64(120), int64(30), true, int64(900), true}; !reflect.DeepEqual(got, want) {
		t.Errorf("finished llm step = %v; want %v", got, want)
	}
	if empty, err := d.ListAutomationRunSteps(999); err != nil || empty == nil || len(empty) != 0 {
		t.Errorf("steps of a missing run = %v, %v; want empty non-nil", empty, err)
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
	b, err = json.Marshal(full)
	if err != nil {
		t.Fatal(err)
	}
	var back AutomationEventPayload
	if err := json.Unmarshal(b, &back); err != nil || !reflect.DeepEqual(back, full) {
		t.Errorf("round trip = %+v, %v; want %+v", back, err, full)
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
	for _, c := range []struct {
		name     string
		from, to time.Time
		want     int64
	}{
		{"day 1 (the 23:59 run)", day1, day2, 110},
		{"day 2 (the 00:01 run)", day2, day3, 210},
		{"empty day", day3, day3.AddDate(0, 0, 1), 0},
	} {
		if n, err := d.AutomationTokensBetween(c.from, c.to); err != nil || n != c.want {
			t.Errorf("%s = %d, %v; want %d", c.name, n, err, c.want)
		}
	}
}

func TestAddAutomationRunUsage_Accumulates(t *testing.T) {
	d := openTestDB(t)
	_, run := seedRunningAutomationRun(t, d)
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
	got := []any{r.InputTokens, r.OutputTokens, r.TokensEstimated, r.ActiveMS, r.ReportedCostUSD != nil && *r.ReportedCostUSD == 1.0}
	if want := []any{int64(12), int64(6), true, int64(40), true}; !reflect.DeepEqual(got, want) {
		t.Errorf("usage = %v; want %v", got, want)
	}
	wantErrIs(t, "usage on a missing run", d.AddAutomationRunUsage(999, RunUsage{}), ErrAutomationRunNotFound)
}

func TestListAutomationRuns_NewestFirstNeverNil(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	first, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	second, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerButton})
	runs, err := d.ListAutomationRuns(a, 0)
	if err != nil || len(runs) != 2 || runs[0].ID != second || runs[1].ID != first {
		t.Errorf("ListAutomationRuns = %+v, %v; want [%d %d]", runs, err, second, first)
	}
	if runs[0].ReportedCostUSD != nil {
		t.Errorf("unreported cost = %v; want nil", *runs[0].ReportedCostUSD)
	}
	if runs, err := d.ListAutomationRuns(12345, 5); err != nil || runs == nil || len(runs) != 0 {
		t.Errorf("runs of a missing automation = %v, %v; want empty non-nil", runs, err)
	}
}
