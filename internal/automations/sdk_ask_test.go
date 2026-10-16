package automations_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// askScript files one question ask and returns what ask() gave back.
const askScript = `const r = ask({kind: "question", title: "Deploy now?", summary: "The build is green.",
	questions: [{question: "Ship it?", options: [{label: "Yes"}, {label: "No"}]}]});
return JSON.stringify(r)`

// catchScript runs call and returns its error as name|message.
func catchScript(call string) string {
	return `try { ` + call + `; return "called" } catch (e) { return e.name + "|" + e.message }`
}

// seedAskAutomation is a confirmed workbench automation declaring ask:owner.
func (w *writeFixture) seedAskAutomation(t *testing.T, script string) db.Automation {
	t.Helper()
	return w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox", script)
}

// asksOf returns workbench wb's asks in every status, newest first.
func (w *writeFixture) asksOf(t *testing.T, wb int64) []db.OwnerAsk {
	t.Helper()
	list, err := w.d.ListOwnerAsks(wb, db.OwnerAskFilter{Statuses: []string{"open", "answered", "delivered", "withdrawn"}})
	if err != nil {
		t.Fatal(err)
	}
	return list
}

// onlyAsk fails unless workbench wb has exactly one ask.
func (w *writeFixture) onlyAsk(t *testing.T, wb int64) db.OwnerAsk {
	t.Helper()
	list := w.asksOf(t, wb)
	if len(list) != 1 {
		t.Fatalf("asks = %+v; want exactly one", list)
	}
	return list[0]
}

// askStep is run id's one ask step.
func (w *writeFixture) askStep(t *testing.T, id int64) db.AutomationRunStep {
	t.Helper()
	var found []db.AutomationRunStep
	for _, s := range w.steps(t, id) {
		if s.Kind == automations.StepKindAsk {
			found = append(found, s)
		}
	}
	if len(found) != 1 {
		t.Fatalf("ask steps = %v; want one", stepStatusesOf(found))
	}
	return found[0]
}

// startAskWait runs a's script until it waits on its ask and returns the
// run and the ask.
func (w *writeFixture) startAskWait(t *testing.T, a db.Automation) (int64, db.OwnerAsk) {
	t.Helper()
	runID := w.enqueue(t, a, db.TriggerManual)
	w.stepNoWait(t, 1)
	w.waitStatus(t, runID, db.RunWaiting)
	if r := w.run(t, runID); r.WaitingReason != db.WaitAsk {
		t.Fatalf("waiting_reason = %q; want ask", r.WaitingReason)
	}
	ask := w.onlyAsk(t, a.ProjectID)
	if s := w.askStep(t, runID); s.Status != automations.StepWaiting || s.AskID != ask.ID || s.FinishedAt != nil {
		t.Fatalf("ask step = %s ask %d finished %v; want an open waiting step linked to %d", s.Status, s.AskID, s.FinishedAt != nil, ask.ID)
	}
	return runID, ask
}

func (w *writeFixture) wantAskWithdrawnByAgent(t *testing.T, wb, id int64) {
	t.Helper()
	a, err := w.d.GetOwnerAsk(wb, id)
	if err != nil {
		t.Fatal(err)
	}
	if a.Status != "withdrawn" || a.WithdrawnReason != db.WithdrawnByAgent {
		t.Fatalf("ask %d = %s/%s; want withdrawn/agent", id, a.Status, a.WithdrawnReason)
	}
}

func TestAsk_WaitsAndDelivers(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedAskAutomation(t, askScript)
	runID, ask := w.startAskWait(t, a)

	if ask.AutomationRunID != (sql.NullInt64{Int64: runID, Valid: true}) || ask.SessionID.Valid || ask.Status != "open" {
		t.Fatalf("ask run %+v session %+v status %s; want run %d, no session, open", ask.AutomationRunID, ask.SessionID, ask.Status, runID)
	}
	var payload asks.Payload
	if err := json.Unmarshal([]byte(ask.Payload), &payload); err != nil {
		t.Fatal(err)
	}
	if ask.Origin != asks.OriginAgent || ask.Level != asks.Level(asks.KindQuestion, payload, asks.OriginAgent) || ask.Level != asks.LevelQuick {
		t.Fatalf("ask origin %s level %s; want agent, quick (asks.Level)", ask.Origin, ask.Level)
	}
	if ask.Kind != asks.KindQuestion || ask.Title != "Deploy now?" || ask.Summary != "The build is green." {
		t.Fatalf("ask = %s %q %q", ask.Kind, ask.Title, ask.Summary)
	}

	// The Desktop's answer write.
	if _, err := w.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = ?,
		answered_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ? AND status = 'open'`,
		`{"answers":[{"id":"1","labels":["Yes"]}],"note":"go"}`, ask.ID); err != nil {
		t.Fatal(err)
	}
	r := w.finishWait(t, runID)
	out := summaryObject(t, r)
	answers, _ := out["answers"].([]any)
	if out["note"] != "go" || len(answers) != 1 || !strings.Contains(r.Summary, `"labels":["Yes"]`) {
		t.Fatalf("script got %s; want the parsed answer", r.Summary)
	}
	if got, err := w.d.GetOwnerAsk(a.ProjectID, ask.ID); err != nil || got.Status != "delivered" {
		t.Fatalf("ask = %+v, %v; want delivered", got, err)
	}
	if s := w.askStep(t, runID); s.Status != automations.StepOK || s.AskID != ask.ID || s.FinishedAt == nil {
		t.Fatalf("ask step = %s ask %d finished %v; want ok, linked to %d", s.Status, s.AskID, s.FinishedAt != nil, ask.ID)
	}
}

func TestAsk_CancelWithdraws(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedAskAutomation(t, askScript)
	runID, ask := w.startAskWait(t, a)
	if ok, err := w.d.CancelAutomationRun(runID, w.clock.Now()); err != nil || !ok {
		t.Fatalf("cancel = (%v, %v)", ok, err)
	}
	w.e.Wake()
	w.e.Wait()
	w.wantRun(t, runID, db.RunCancelled, db.ErrKindCancelled)
	w.wantAskWithdrawnByAgent(t, a.ProjectID, ask.ID)
}

func TestAsk_ExpiryWithdraws(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedAskAutomation(t, askScript)
	runID, ask := w.startAskWait(t, a)
	w.clock.Advance(time.Duration(a.PauseTimeoutHours)*time.Hour + time.Minute)
	w.e.Wake()
	w.e.Wait()
	w.wantRun(t, runID, db.RunExpired, db.ErrKindExpired)
	w.wantAskWithdrawnByAgent(t, a.ProjectID, ask.ID)
}

// Ruling R-P5-5: a review needs a document and a session to re-round it.
func TestAsk_ReviewKindRefused(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedAskAutomation(t, catchScript(`ask({kind: "review", title: "Read the plan"})`))
	r := w.runToEnd(t, a)
	if !strings.HasPrefix(r.Summary, automations.ErrNameValidation+"|") || !strings.Contains(r.Summary, "review") {
		t.Fatalf("script got %q; want a ValidationError naming review", r.Summary)
	}
	if list := w.asksOf(t, a.ProjectID); len(list) != 0 {
		t.Fatalf("asks = %+v; want none", list)
	}
	if s := w.askStep(t, r.ID); s.Status != automations.StepError {
		t.Fatalf("ask step = %s; want error", s.Status)
	}
}

func TestAsk_BadInputIsValidationError(t *testing.T) {
	for name, call := range map[string]string{
		"unknown key":  `ask({kind: "question", title: "t", doc_path: "plan.md", questions: [{question: "q", options: [{label: "a"}, {label: "b"}]}]})`,
		"no title":     `ask({kind: "check", checklist: [{text: "run it"}]})`,
		"not object":   `ask("Deploy?")`,
		"unknown kind": `ask({kind: "poll", title: "t"})`,
	} {
		t.Run(name, func(t *testing.T) {
			w := newWriteFixture(t)
			a := w.seedAskAutomation(t, catchScript(call))
			r := w.runToEnd(t, a)
			if !strings.HasPrefix(r.Summary, automations.ErrNameValidation+"|") {
				t.Fatalf("script got %q; want a ValidationError", r.Summary)
			}
			if list := w.asksOf(t, a.ProjectID); len(list) != 0 {
				t.Fatalf("asks = %+v; want none", list)
			}
		})
	}
}

// A personal automation cannot declare ask:owner (D7), so its manifest
// refuses the call.
func TestAsk_PersonalDenied(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWrite(t, []string{"llm:light"}, "", `try { ask({kind: "question", title: "t",
		questions: [{question: "q", options: [{label: "a"}, {label: "b"}]}]}); return "called" }
		catch (e) { return e.name + "|" + e.needed }`)
	r := w.runToEnd(t, a)
	if r.Summary != automations.ErrNamePermissionDenied+"|ask:owner" {
		t.Fatalf("script got %q; want PermissionDenied needing ask:owner", r.Summary)
	}
	if s := w.askStep(t, r.ID); s.Status != automations.StepDenied {
		t.Fatalf("ask step = %s; want denied", s.Status)
	}
	if n := w.count(t, "owner_asks"); n != 0 {
		t.Fatalf("owner_asks = %d rows; want none", n)
	}
}

func TestAsk_CapReachedIsToolError(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedAskAutomation(t, catchScript(`ask({kind: "check", title: "Run the smoke test", checklist: [{text: "open the app"}]})`))
	for i := range asks.MaxOpenPerWorkbench {
		if err := w.d.WithTx(func(tx *sql.Tx) error {
			_, _, err := w.d.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: a.ProjectID, Kind: "question", Title: "Open " + string(rune('a'+i))})
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
	r := w.runToEnd(t, a)
	if r.Summary != automations.ErrNameTool+"|this workbench has 30 open asks; answer some first" {
		t.Fatalf("script got %q; want the cap's ToolError", r.Summary)
	}
	if n := w.count(t, "owner_asks"); n != asks.MaxOpenPerWorkbench {
		t.Fatalf("owner_asks = %d rows; want %d (no new row)", n, asks.MaxOpenPerWorkbench)
	}
}

func TestAsk_DryRunCreatesNoRow(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedAskAutomation(t, askScript)
	id := w.enqueue(t, a, db.TriggerDryRun)
	r, err := w.e.ExecuteInline(context.Background(), id)
	if err != nil || r.Status != db.RunSucceeded {
		t.Fatalf("ExecuteInline = %+v, %v; want succeeded", r, err)
	}
	if r.Summary != `{"status":"dry_run"}` {
		t.Fatalf("script got %q; want {status: dry_run}", r.Summary)
	}
	if n := w.count(t, "owner_asks"); n != 0 {
		t.Fatalf("owner_asks = %d rows; want none", n)
	}
}

// A daemon restart ends a run left running (AUTO-08) and withdraws its open
// ask (D6): no run waits for it any more.
func TestExecutorSweep_WithdrawsAsksOfTerminalRuns(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedAskAutomation(t, askScript)
	runID := w.enqueue(t, a, db.TriggerManual)
	w.claimAt(t, a, runID, exStart.Add(-time.Minute))
	var askID int64
	if err := w.d.WithTx(func(tx *sql.Tx) error {
		var err error
		askID, _, err = w.d.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: a.ProjectID, Kind: "question", Title: "Left open",
			AutomationRunID: sql.NullInt64{Int64: runID, Valid: true}})
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := w.e.Run(cancelledCtx()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	w.wantRun(t, runID, db.RunFailed, db.ErrKindInterrupted)
	w.wantAskWithdrawnByAgent(t, a.ProjectID, askID)
}
