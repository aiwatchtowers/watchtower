package automations_test

import (
	"context"
	"encoding/json"
	"log"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

// sessRecipe is a manual workbench recipe named "PR review"; PERMS
// (permission lines), EXTRA (more frontmatter lines) and SCRIPT are replaced.
const sessRecipe = "---\nname: PR review\ntrigger:\n  manual: true\npermissions:\nPERMS" +
	"outputs: [report]\nEXTRA---\nSessions for the SDK session tests.\n\n```js\nSCRIPT\n```\n"

func sessRecipeText(perms []string, extra, script string) string {
	var lines strings.Builder
	for _, p := range perms {
		lines.WriteString("  - " + p + "\n")
	}
	return strings.NewReplacer("PERMS", lines.String(), "EXTRA", extra, "SCRIPT", script).Replace(sessRecipe)
}

// sessFixture is an executor over a file DB whose Backends resolve one
// workbench (default agent: agent) for the session() tests; the test plays
// the Desktop with the db calls `automations session-launched/-ended` make.
type sessFixture struct {
	*exFixture
	wb     int64
	folder string
	agent  string
}

func newSessFixture(t *testing.T, defaultAgent string) *sessFixture {
	t.Helper()
	s := &sessFixture{exFixture: newExFixture(t, exOpts{fileDB: true}), agent: defaultAgent}
	s.wb, s.folder = newWorkbench(t, s.d)
	s.e = automations.NewExecutor(s.d, automations.Backends{DB: s.d, Generator: s.gen, Registry: s.reg, Clock: s.clock,
		Workbench: automations.NewWorkbenchResolver(s.d, func() string { return s.agent }, func(string) bool { return false })},
		automations.ExecutorOptions{Modules: automations.DefaultModules, Logger: log.New(s.logs, "", 0)})
	return s
}

// seedSession indexes, confirms and enables the workbench recipe.
func (s *sessFixture) seedSession(t *testing.T, perms []string, extra, script string) db.Automation {
	t.Helper()
	writeWorkbenchRecipe(t, s.folder, "review", sessRecipeText(perms, extra, script))
	rescanWorkbench(t, s.ix, s.wb, s.folder)
	a := workbenchRow(t, s.d, s.wb, "review")
	if a.ParseError != "" {
		t.Fatalf("the recipe does not parse: %s", a.ParseError)
	}
	if err := s.d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
		t.Fatal(err)
	}
	if err := s.d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
		t.Fatal(err)
	}
	return workbenchRow(t, s.d, s.wb, "review")
}

// startSession runs a until it waits for the app with one pending session
// step; it returns the run and that step.
func (s *sessFixture) startSession(t *testing.T, a db.Automation) (int64, db.PendingSessionStep) {
	t.Helper()
	runID := s.enqueue(t, a, db.TriggerManual)
	s.stepNoWait(t, 1)
	s.waitStatus(t, runID, db.RunWaiting)
	if r := s.run(t, runID); r.WaitingReason != db.WaitApp {
		t.Fatalf("waiting_reason = %q; want app", r.WaitingReason)
	}
	pending, err := s.d.PendingAutomationSessionSteps()
	if err != nil || len(pending) != 1 || pending[0].RunID != runID || pending[0].WorkbenchID != s.wb {
		t.Fatalf("pending = %+v, %v; want one step of run %d", pending, err, runID)
	}
	st := s.sessionStep(t, runID)
	if st.Status != automations.StepWaiting || st.FinishedAt != nil || st.ID != pending[0].StepID {
		t.Fatalf("step = %+v; want an open waiting session step", st)
	}
	return runID, pending[0]
}

// launch plays the Desktop: a session row of the run, attached to the step,
// then the CLI's wake.
func (s *sessFixture) launch(t *testing.T, runID, stepID int64) int64 {
	t.Helper()
	res, err := s.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, automation_run_id)
		VALUES (?, 'claude', 'PR review', ?, 'uuid', ?)`, s.wb, s.folder, runID)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := s.d.AttachAutomationSessionStep(stepID, id); err != nil || !ok {
		t.Fatalf("attach = (%v, %v)", ok, err)
	}
	s.e.Wake()
	return id
}

// waitReason waits (real time) until run id waits with reason.
func (s *sessFixture) waitReason(t *testing.T, id int64, reason string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		r := s.run(t, id)
		if r.Status == db.RunWaiting && r.WaitingReason == reason {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("run %d never waited for %s (is %s/%s)", id, reason, r.Status, r.WaitingReason)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (s *sessFixture) setSession(t *testing.T, id int64, set string) {
	t.Helper()
	if _, err := s.d.Exec(`UPDATE terminal_sessions SET `+set+` WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
}

// finish wakes the executor and waits for run id to end with status.
func (s *sessFixture) finish(t *testing.T, id int64, status, kind string) *db.AutomationRun {
	t.Helper()
	s.e.Wake()
	s.e.Wait()
	return s.wantRun(t, id, status, kind)
}

// cancel cancels waiting run id and waits for the executor to drop it.
func (s *sessFixture) cancel(t *testing.T, id int64) {
	t.Helper()
	if ok, err := s.d.CancelAutomationRun(id, s.clock.Now()); err != nil || !ok {
		t.Fatalf("cancel = (%v, %v)", ok, err)
	}
	s.finish(t, id, db.RunCancelled, db.ErrKindCancelled)
}

func (s *sessFixture) sessionStep(t *testing.T, runID int64) db.AutomationRunStep {
	t.Helper()
	for _, st := range s.steps(t, runID) {
		if st.Kind == "session" {
			return st
		}
	}
	t.Fatalf("run %d has no session step: %s", runID, stepStatusesOf(s.steps(t, runID)))
	return db.AutomationRunStep{}
}

const sessScript = `return JSON.stringify(session({prompt: "Review PR 7 and file findings with ask_owner"}))`

func TestSession_WaitsForAppThenSessionThenFinish(t *testing.T) {
	s := newSessFixture(t, "claude")
	runID, p := s.startSession(t, s.seedSession(t, []string{"session:start"}, "", sessScript))
	var args map[string]string
	if err := json.Unmarshal([]byte(p.ArgsJSON), &args); err != nil {
		t.Fatalf("args_json %q: %v", p.ArgsJSON, err)
	}
	wantTitle := "⚙ PR review · run #" + strconv.FormatInt(runID, 10)
	if args["prompt"] != "Review PR 7 and file findings with ask_owner" || args["agent"] != "claude" || args["title"] != wantTitle {
		t.Fatalf("args = %v; want the prompt, agent claude, title %q", args, wantTitle)
	}

	sess := s.launch(t, runID, p.StepID)
	s.waitReason(t, runID, db.WaitSession)
	if st := s.sessionStep(t, runID); st.Status != automations.StepWaiting || st.SessionID != sess || st.FinishedAt != nil {
		t.Fatalf("step = %+v; want still waiting, naming session %d", st, sess)
	}

	s.setSession(t, sess, `finished_at = '2026-10-14T12:30:00.000Z', finish_summary = 'Two findings filed'`)
	r := s.finish(t, runID, db.RunSucceeded, "")
	out := summaryObject(t, r)
	if out["status"] != "finished" || out["summary"] != "Two findings filed" || out["session_id"] != float64(sess) {
		t.Fatalf("script got %v; want finished with the summary of session %d", out, sess)
	}
	if _, has := out["error"]; has {
		t.Fatalf("script got %v; want no error key on a finished session", out)
	}
	if st := s.sessionStep(t, runID); st.Status != automations.StepOK || st.SessionID != sess || st.FinishedAt == nil ||
		st.Permission != "session:start" {
		t.Fatalf("step = %+v; want ok, finished, session %d, permission session:start", st, sess)
	}
}

func TestSession_ErrorDeletedStopped(t *testing.T) {
	cases := []struct {
		name   string
		end    func(t *testing.T, s *sessFixture, stepID, sess int64)
		status string
		errMsg string
	}{
		{"error", func(t *testing.T, s *sessFixture, _, sess int64) {
			s.setSession(t, sess, `agent_failed_at = '2026-10-14T12:30:00.000Z', agent_error = 'overloaded_error'`)
		}, "error", "overloaded_error"},
		{"deleted", func(t *testing.T, s *sessFixture, _, sess int64) {
			if _, err := s.d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sess); err != nil {
				t.Fatal(err)
			}
		}, "deleted", ""},
		{"stopped", func(t *testing.T, s *sessFixture, stepID, _ int64) {
			if ok, err := s.d.EndAutomationSessionStep(stepID, db.SessionStepStopped, ""); err != nil || !ok {
				t.Fatalf("end = (%v, %v)", ok, err)
			}
		}, "stopped", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newSessFixture(t, "claude")
			runID, p := s.startSession(t, s.seedSession(t, []string{"session:start"}, "", sessScript))
			sess := s.launch(t, runID, p.StepID)
			s.waitReason(t, runID, db.WaitSession)
			tc.end(t, s, p.StepID, sess)
			out := summaryObject(t, s.finish(t, runID, db.RunSucceeded, ""))
			if out["status"] != tc.status || out["session_id"] != float64(sess) {
				t.Fatalf("script got %v; want status %s for session %d", out, tc.status, sess)
			}
			if got, _ := out["error"].(string); got != tc.errMsg {
				t.Fatalf("error = %q; want %q", got, tc.errMsg)
			}
			if st := s.sessionStep(t, runID); st.Status != automations.StepOK || st.FinishedAt == nil || st.SessionID != sess {
				t.Fatalf("step = %+v; want closed ok naming session %d", st, sess)
			}
		})
	}
}

// R-P5-3: a turn that ends without finish_session (PROJ-11's idle Stopped)
// is no end — the run keeps waiting until the Desktop reports one.
func TestSession_IdleTurnKeepsTheRunWaiting(t *testing.T) {
	s := newSessFixture(t, "claude")
	runID, p := s.startSession(t, s.seedSession(t, []string{"session:start"}, "", sessScript))
	sess := s.launch(t, runID, p.StepID)
	s.waitReason(t, runID, db.WaitSession)
	s.setSession(t, sess, `agent_state = 'waiting', agent_state_at = '2026-10-14T12:30:00.000Z'`)
	s.e.Wake()
	time.Sleep(50 * time.Millisecond)
	s.waitReason(t, runID, db.WaitSession)
	s.cancel(t, runID)
}

func TestSession_LaunchFailedThrowsNotAvailable(t *testing.T) {
	s := newSessFixture(t, "codex")
	runID, p := s.startSession(t, s.seedSession(t, []string{"session:start"}, "",
		`try { session({prompt: "Check the deploy"}); return "launched" } catch (e) { return e.name + "|" + e.message }`))
	if ok, err := s.d.EndAutomationSessionStep(p.StepID, db.SessionStepLaunchFailed, "Codex was not found"); err != nil || !ok {
		t.Fatalf("end = (%v, %v)", ok, err)
	}
	r := s.finish(t, runID, db.RunSucceeded, "")
	if r.Summary != "NotAvailable|Codex was not found" {
		t.Fatalf("script got %q; want NotAvailable with the Desktop's reason", r.Summary)
	}
	if st := s.sessionStep(t, runID); st.Status != automations.StepError || st.FinishedAt == nil ||
		!strings.Contains(st.Error, "Codex was not found") {
		t.Fatalf("step = %+v; want closed error with the reason", st)
	}
}

func TestSession_WaitNoneReturnsAfterLaunch(t *testing.T) {
	s := newSessFixture(t, "claude")
	runID, p := s.startSession(t, s.seedSession(t, []string{"session:start"}, "",
		`var r = session({prompt: "Check the deploy", wait: "none"}); log("after launch"); return JSON.stringify(r)`))
	sess := s.launch(t, runID, p.StepID)
	out := summaryObject(t, s.finish(t, runID, db.RunSucceeded, ""))
	if len(out) != 1 || out["session_id"] != float64(sess) {
		t.Fatalf("script got %v; want only {session_id: %d}", out, sess)
	}
	if got := stepStatusesOf(s.steps(t, runID)); got != "session:ok,log:ok" {
		t.Fatalf("steps = %s; want the session step ok, then the script went on", got)
	}
	if st := s.sessionStep(t, runID); st.SessionID != sess {
		t.Fatalf("step session = %d; want %d", st.SessionID, sess)
	}
}

func TestSession_AgentDefaultAndPermission(t *testing.T) {
	const catchScript = `try { return JSON.stringify(session(OPTS)) } catch (e) { return e.name + "|" + e.needed }`
	t.Run("default codex is not admitted by session:start@claude", func(t *testing.T) {
		s := newSessFixture(t, "codex")
		a := s.seedSession(t, []string{"session:start@claude"}, "", strings.Replace(catchScript, "OPTS", `{prompt: "x"}`, 1))
		id := s.enqueue(t, a, db.TriggerManual)
		s.step(t, 1)
		if r := s.wantRun(t, id, db.RunSucceeded, ""); r.Summary != "PermissionDenied|session:start@codex" {
			t.Fatalf("script got %q; want PermissionDenied needing session:start@codex", r.Summary)
		}
		if st := s.sessionStep(t, id); st.Status != automations.StepDenied || st.Permission != "session:start@codex" {
			t.Fatalf("step = %+v; want denied needing session:start@codex", st)
		}
		if pending, _ := s.d.PendingAutomationSessionSteps(); len(pending) != 0 {
			t.Fatalf("a denied call left a request for the Desktop: %+v", pending)
		}
	})
	for _, tc := range []struct{ opts, agent string }{{`{prompt: "x"}`, "codex"}, {`{prompt: "x", agent: "claude"}`, "claude"}} {
		t.Run("session:start admits "+tc.agent, func(t *testing.T) {
			s := newSessFixture(t, "codex")
			runID, p := s.startSession(t, s.seedSession(t, []string{"session:start"}, "", strings.Replace(catchScript, "OPTS", tc.opts, 1)))
			if !strings.Contains(p.ArgsJSON, `"agent":"`+tc.agent+`"`) {
				t.Fatalf("args = %s; want agent %s", p.ArgsJSON, tc.agent)
			}
			if st := s.sessionStep(t, runID); st.Name != tc.agent {
				t.Fatalf("step name = %q; want %s", st.Name, tc.agent)
			}
			s.cancel(t, runID)
		})
	}
	t.Run("session:start@codex admits an explicit codex", func(t *testing.T) {
		s := newSessFixture(t, "claude")
		runID, p := s.startSession(t, s.seedSession(t, []string{"session:start@codex"}, "",
			strings.Replace(catchScript, "OPTS", `{prompt: "x", agent: "codex"}`, 1)))
		if !strings.Contains(p.ArgsJSON, `"agent":"codex"`) {
			t.Fatalf("args = %s; want agent codex", p.ArgsJSON)
		}
		s.cancel(t, runID)
	})
}

// sessDryRun dry-runs a workbench recipe in memory over a resolver whose
// default agent is claude.
func sessDryRun(t *testing.T, perms []string, script string, scope func(wb int64) automations.Scope) *automations.DryRunReport {
	t.Helper()
	d := db.OpenTestDB(t)
	wb, _ := newWorkbench(t, d)
	r, err := automations.ParseRecipe("review", []byte(sessRecipeText(perms, "", script)), scope(wb))
	if err != nil {
		t.Fatalf("ParseRecipe: %v", err)
	}
	b := automations.Backends{DB: d, Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart),
		Workbench: automations.NewWorkbenchResolver(d, func() string { return "claude" }, func(string) bool { return false })}
	rep, err := automations.DryRunInMemory(context.Background(), b, r, automations.DryRunOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return rep
}

func sessWorkbenchScope(wb int64) automations.Scope {
	return automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: wb}
}

func onlySessionStep(t *testing.T, steps []db.AutomationRunStep) db.AutomationRunStep {
	t.Helper()
	if len(steps) != 1 || steps[0].Kind != "session" {
		t.Fatalf("steps = %s; want one session step", stepStatusesOf(steps))
	}
	return steps[0]
}

func TestSession_PersonalRecipeDenied(t *testing.T) {
	rep := sessDryRun(t, []string{"llm:light"}, `session({prompt: "x"})`,
		func(int64) automations.Scope { return automations.Scope{Kind: automations.ScopePersonal} })
	st := onlySessionStep(t, rep.Steps)
	if st.Status != automations.StepDenied {
		t.Fatalf("step = %+v; want denied", st)
	}
	if rep.Status != db.RunFailed || !strings.Contains(rep.Error, "PermissionDenied") ||
		!strings.Contains(rep.Error, "workbench automations only") {
		t.Fatalf("dry run = %s (%s); want failed on PermissionDenied naming workbench automations", rep.Status, rep.Error)
	}
}

func TestSession_DryRunWaitsForNothing(t *testing.T) {
	rep := sessDryRun(t, []string{"session:start"}, `return session({prompt: "x"}).status`, sessWorkbenchScope)
	st := onlySessionStep(t, rep.Steps)
	if rep.Status != db.RunSucceeded || st.Status != automations.StepDryRun || !strings.Contains(st.ResultSummary, `"agent":"claude"`) {
		t.Fatalf("dry run = %s (%s), step %+v; want succeeded with a dry_run step", rep.Status, rep.Error, st)
	}
}

func TestSession_Validation(t *testing.T) {
	for _, tc := range []struct{ name, opts, want string }{
		{"empty prompt", `{prompt: ""}`, "prompt"},
		{"no options", ``, "options"},
		{"prompt too long", `{prompt: "a".repeat(16385)}`, "16384"},
		{"title too long", `{prompt: "x", title: "é".repeat(81)}`, "80"},
		{"unknown agent", `{prompt: "x", agent: "x"}`, "agent"},
		{"unknown wait", `{prompt: "x", wait: "later"}`, "wait"},
		{"unknown option", `{prompt: "x", cwd: "/tmp"}`, "cwd"},
		{"prompt over the journal's args", `{prompt: "a".repeat(5000)}`, "4096"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rep := sessDryRun(t, []string{"session:start"}, `session(`+tc.opts+`)`, sessWorkbenchScope)
			st := onlySessionStep(t, rep.Steps)
			if st.Status != automations.StepError || !strings.Contains(st.Error, "ValidationError") || !strings.Contains(st.Error, tc.want) {
				t.Fatalf("step = %s %q; want a ValidationError naming %q", st.Status, st.Error, tc.want)
			}
		})
	}
	t.Run("80-rune title is accepted", func(t *testing.T) {
		rep := sessDryRun(t, []string{"session:start"}, `session({prompt: "x", title: "é".repeat(80)})`, sessWorkbenchScope)
		if st := onlySessionStep(t, rep.Steps); st.Status != automations.StepDryRun {
			t.Fatalf("step = %s %q; want dry_run", st.Status, st.Error)
		}
	})
}

func TestSession_PauseExcludedFromActiveTime(t *testing.T) {
	s := newSessFixture(t, "claude")
	runID, p := s.startSession(t, s.seedSession(t, []string{"session:start"}, "", sessScript))
	s.clock.Advance(2 * time.Hour)
	sess := s.launch(t, runID, p.StepID)
	s.waitReason(t, runID, db.WaitSession)
	s.setSession(t, sess, `finished_at = '2026-10-14T14:00:00.000Z', finish_summary = 'done'`)
	r := s.finish(t, runID, db.RunSucceeded, "")
	if r.ActiveMS >= (5 * time.Minute).Milliseconds() {
		t.Fatalf("active_ms = %d; want the 2 h of waiting excluded from the 5-minute budget", r.ActiveMS)
	}
}

func TestSession_PauseTimeoutExpires(t *testing.T) {
	s := newSessFixture(t, "claude")
	runID, p := s.startSession(t, s.seedSession(t, []string{"session:start"}, "pause_timeout_hours: 1\n", sessScript))
	s.clock.Advance(61 * time.Minute)
	s.finish(t, runID, db.RunExpired, db.ErrKindExpired)
	if st := s.sessionStep(t, runID); st.Status != automations.StepError || st.FinishedAt == nil {
		t.Fatalf("step = %+v; want closed error", st)
	}
	if pending, _ := s.d.PendingAutomationSessionSteps(); len(pending) != 0 {
		t.Fatalf("an expired run still asks the Desktop for a session: %+v", pending)
	}
	if ok, err := s.d.AttachAutomationSessionStep(p.StepID, 1); err != nil || ok {
		t.Fatalf("attach after expiry = (%v, %v); want false", ok, err)
	}
}
