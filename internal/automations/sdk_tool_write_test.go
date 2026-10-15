package automations_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// writeRecipe is a manual recipe named "New mail summary"; PERMS (permission
// lines), EXTRA (more frontmatter lines) and SCRIPT are replaced.
const writeRecipe = "---\nname: New mail summary\ntrigger:\n  manual: true\npermissions:\nPERMS" +
	"outputs: [inbox]\nEXTRA---\nWrites for the SDK write tests.\n\n```js\nSCRIPT\n```\n"

// writeFixture is an executor over a file DB whose registry is a real
// tools.Registry with create_target, create_idea and create_jira_issue.
type writeFixture struct {
	*exFixture
	reg *tools.Registry
}

func newWriteFixture(t *testing.T) *writeFixture {
	t.Helper()
	w := &writeFixture{}
	w.exFixture = newExFixture(t, exOpts{fileDB: true, registry: func(d *db.DB) automations.ToolRegistry {
		w.reg = tools.New(d)
		for _, tl := range []*tools.Tool{tools.NewCreateTarget(), tools.NewCreateIdea(), tools.NewCreateJiraIssue(nil), editNoteTool(t)} {
			if err := w.reg.Register(tl); err != nil {
				t.Fatalf("register %s: %v", tl.Name, err)
			}
		}
		return w.reg
	}})
	return w
}

// noteArgs is what the fake edit_note write tool takes.
type noteArgs struct {
	Text   string `json:"text"`
	Reason string `json:"reason"`
}

// editNoteTool is a fake automation write tool that takes owner edits
// (Revise replaces text) and returns the text it applied.
func editNoteTool(t *testing.T) *tools.Tool {
	t.Helper()
	schema, err := jsonschema.For[noteArgs](nil)
	if err != nil {
		t.Fatal(err)
	}
	return &tools.Tool{
		Name: "edit_note", Description: "fake write with edits", InputSchema: schema, Access: tools.AccessWrite,
		Surfaces: []string{tools.AutomationSurface},
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Revise: func(_ context.Context, _ *db.DB, args, patch json.RawMessage) (json.RawMessage, error) {
			var a, p noteArgs
			if err := json.Unmarshal(args, &a); err != nil {
				return nil, err
			}
			if err := json.Unmarshal(patch, &p); err != nil {
				return nil, err
			}
			a.Text = p.Text
			return json.Marshal(a)
		},
		Execute: func(_ context.Context, _ *db.DB, call tools.Call) (any, error) {
			var a noteArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, err
			}
			return map[string]any{"text": a.Text}, nil
		},
	}
}

// seedWrite indexes, confirms and enables a recipe with perms and script.
func (w *writeFixture) seedWrite(t *testing.T, perms []string, extra, script string) db.Automation {
	t.Helper()
	var lines strings.Builder
	for _, p := range perms {
		lines.WriteString("  - " + p + "\n")
	}
	text := strings.NewReplacer("PERMS", lines.String(), "EXTRA", extra, "SCRIPT", script).Replace(writeRecipe)
	return w.seedText(t, "mail", text, false)
}

// runToEnd runs one queued run of a to its end and returns the run.
func (w *writeFixture) runToEnd(t *testing.T, a db.Automation) *db.AutomationRun {
	t.Helper()
	id := w.enqueue(t, a, db.TriggerManual)
	w.step(t, 1)
	return w.run(t, id)
}

// actions returns every agent_actions row.
func (w *writeFixture) actions(t *testing.T) []db.AgentAction {
	t.Helper()
	rows, err := w.d.ListAgentActions(db.AgentActionFilter{})
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// onlyAction fails unless exactly one agent_actions row exists.
func (w *writeFixture) onlyAction(t *testing.T) db.AgentAction {
	t.Helper()
	rows := w.actions(t)
	if len(rows) != 1 {
		t.Fatalf("agent_actions = %+v; want exactly one row", rows)
	}
	return rows[0]
}

// toolStep is run id's one tool step.
func (w *writeFixture) toolStep(t *testing.T, id int64) db.AutomationRunStep {
	t.Helper()
	var found []db.AutomationRunStep
	for _, s := range w.steps(t, id) {
		if s.Kind == automations.StepKindTool {
			found = append(found, s)
		}
	}
	if len(found) != 1 {
		t.Fatalf("tool steps = %v; want one", stepStatusesOf(found))
	}
	return found[0]
}

// summaryObject decodes the run summary (the script returns JSON.stringify).
func summaryObject(t *testing.T, r *db.AutomationRun) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal([]byte(r.Summary), &out); err != nil {
		t.Fatalf("run summary %q is not a JSON object: %v", r.Summary, err)
	}
	return out
}

func wantStep(t *testing.T, s db.AutomationRunStep, status string, actionID int64, auto bool) {
	t.Helper()
	if s.Status != status || s.ActionID != actionID || s.Auto != auto || s.FinishedAt == nil {
		t.Fatalf("step = %s action %d auto %v finished %v; want %s action %d auto %v finished",
			s.Status, s.ActionID, s.Auto, s.FinishedAt != nil, status, actionID, auto)
	}
}

func idOf(t *testing.T, out map[string]any) int64 {
	t.Helper()
	id, ok := out["id"].(float64)
	if !ok {
		t.Fatalf("result %v has no numeric id", out)
	}
	return int64(id)
}

const createTargetScript = `return JSON.stringify(tool("create_target", {text: "Reply to acme", reason: "scheduled"}))`

func TestAuto02_ToolWriteGoesThroughPropose(t *testing.T) {
	w := newWriteFixture(t)
	r := w.runToEnd(t, w.seedWrite(t, []string{"tool:create_target"}, "", createTargetScript))
	if r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	row := w.onlyAction(t)
	if row.Status != "pending" || row.ContextType != tools.AutomationContextType ||
		row.ContextID != fmt.Sprint(r.ID) || row.Surface != tools.AutomationSurface || row.TrustAtCreate != "ask" {
		t.Fatalf("row = %+v; want pending, ask, automation_run/%d on the automation surface", row, r.ID)
	}
	if n := w.count(t, "targets"); n != 0 {
		t.Fatalf("targets = %d; want none before an approval", n)
	}
	out := summaryObject(t, r)
	if out["status"] != "proposed" || idOf(t, out) != row.ID || len(out) != 2 {
		t.Fatalf("script got %v; want {status: proposed, id: %d}", out, row.ID)
	}
	s := w.toolStep(t, r.ID)
	wantStep(t, s, automations.StepProposed, row.ID, false)
	if s.Permission != "tool:create_target" {
		t.Fatalf("step permission = %q; want tool:create_target", s.Permission)
	}
}

func TestToolWrite_PermissionDeniedTouchesNothing(t *testing.T) {
	w := newWriteFixture(t)
	script := `try { tool("create_jira_issue", {project_key: "OPS", issue_type: "Task", summary: "x"}); return "called" }
		catch (e) { return e.name + "|" + e.needed }`
	r := w.runToEnd(t, w.seedWrite(t, []string{"jira:write@PAY"}, "", script))
	if r.Status != db.RunSucceeded || r.Summary != "PermissionDenied|jira:write@OPS" {
		t.Fatalf("run = %s, summary %q; want succeeded with PermissionDenied|jira:write@OPS", r.Status, r.Summary)
	}
	if rows := w.actions(t); len(rows) != 0 {
		t.Fatalf("agent_actions = %+v; want none", rows)
	}
	if s := w.toolStep(t, r.ID); s.Status != automations.StepDenied || s.ActionID != 0 {
		t.Fatalf("step = %s action %d; want denied, no action", s.Status, s.ActionID)
	}
}

func TestToolWrite_AutoGrantStepIsAppliedAuto(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWrite(t, []string{"tool:create_target"}, "", createTargetScript)
	if err := w.d.SetAutomationToolGrant(a.ID, "create_target", a.ApprovalHash, exStart); err != nil {
		t.Fatal(err)
	}
	r := w.runToEnd(t, a)
	row := w.onlyAction(t)
	if row.Status != "applied" || row.TrustAtCreate != "execute" || row.ContextType != tools.AutomationContextType {
		t.Fatalf("row = %+v; want applied, execute, automation_run", row)
	}
	out := summaryObject(t, r)
	if out["status"] != "applied" || idOf(t, out) != row.ID || out["result"] == nil {
		t.Fatalf("script got %v; want {status: applied, id: %d, result}", out, row.ID)
	}
	if n := w.count(t, "targets"); n != 1 {
		t.Fatalf("targets = %d; want the auto write's one", n)
	}
	wantStep(t, w.toolStep(t, r.ID), automations.StepApplied, row.ID, true)
}

func TestToolWrite_TrustExecuteStepIsAppliedNotAuto(t *testing.T) {
	w := newWriteFixture(t)
	if err := w.d.SetToolTrust("create_idea", tools.AutomationSurface, "execute"); err != nil {
		t.Fatal(err)
	}
	r := w.runToEnd(t, w.seedWrite(t, []string{"tool:create_idea"}, "",
		`return JSON.stringify(tool("create_idea", {essence: "Batch the mail", reason: "scheduled"}))`))
	row := w.onlyAction(t)
	if row.Status != "applied" || summaryObject(t, r)["status"] != "applied" {
		t.Fatalf("row %s, script got %s; want applied", row.Status, r.Summary)
	}
	wantStep(t, w.toolStep(t, r.ID), automations.StepApplied, row.ID, false)
}

func TestToolWrite_DefaultReason(t *testing.T) {
	cases := []struct{ name, args, want string }{
		{"absent", `{text: "x"}`, "⚙ New mail summary · run #%d"},
		{"blank", `{text: "x", reason: "  "}`, "⚙ New mail summary · run #%d"},
		{"null", `{text: "x", reason: null}`, "⚙ New mail summary · run #%d"},
		{"given", `{text: "x", reason: " Mail from acme piled up "}`, " Mail from acme piled up "},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWriteFixture(t)
			r := w.runToEnd(t, w.seedWrite(t, []string{"tool:create_target"}, "",
				`return JSON.stringify(tool("create_target", `+tc.args+`))`))
			want := tc.want
			if strings.Contains(want, "%d") {
				want = fmt.Sprintf(want, r.ID)
			}
			row := w.onlyAction(t)
			if row.Reason != strings.TrimSpace(want) && row.Reason != want {
				t.Fatalf("reason = %q; want %q", row.Reason, want)
			}
			var args map[string]any
			if err := json.Unmarshal([]byte(row.ArgsJSON), &args); err != nil || args["reason"] != want {
				t.Fatalf("args_json reason = %q (%v); want %q verbatim", args["reason"], err, want)
			}
		})
	}
}

// waitScript proposes create_target with {wait:true} and returns the result.
const waitScript = `return JSON.stringify(tool("create_target", {text: "Reply to acme", reason: "scheduled"}, {wait: true}))`

// startWaiting runs a's wait script until the run is waiting on the
// approval of its one proposal; it returns the run and action ids.
func (w *writeFixture) startWaiting(t *testing.T, a db.Automation) (runID, actionID int64) {
	t.Helper()
	runID = w.enqueue(t, a, db.TriggerManual)
	w.stepNoWait(t, 1)
	w.waitStatus(t, runID, db.RunWaiting)
	if r := w.run(t, runID); r.WaitingReason != db.WaitApproval {
		t.Fatalf("waiting_reason = %q; want approval", r.WaitingReason)
	}
	row := w.onlyAction(t)
	if row.Status != "pending" {
		t.Fatalf("row = %s; want pending while waiting", row.Status)
	}
	if s := w.toolStep(t, runID); s.Status != automations.StepWaiting || s.ActionID != row.ID || s.FinishedAt != nil {
		t.Fatalf("step = %s action %d; want an open waiting step linked to %d", s.Status, s.ActionID, row.ID)
	}
	return runID, row.ID
}

// finishWait wakes the executor after a decision and waits for the run.
func (w *writeFixture) finishWait(t *testing.T, runID int64) *db.AutomationRun {
	t.Helper()
	w.e.Wake()
	w.e.Wait()
	return w.wantRun(t, runID, db.RunSucceeded, "")
}

func (w *writeFixture) approveAndApply(t *testing.T, id int64) {
	t.Helper()
	if ok, err := w.reg.Approve(context.Background(), id, nil); err != nil || !ok {
		t.Fatalf("approve = (%v, %v)", ok, err)
	}
	if _, err := w.reg.Apply(context.Background(), id); err != nil {
		t.Fatalf("apply: %v", err)
	}
}

func (w *writeFixture) transition(t *testing.T, id int64, from, to, errMsg string) {
	t.Helper()
	if ok, err := w.d.TransitionAgentAction(id, []string{from}, to, "", errMsg); err != nil || !ok {
		t.Fatalf("transition %s→%s = (%v, %v)", from, to, ok, err)
	}
}

func TestToolWait_AppliedRejectedFailed(t *testing.T) {
	cases := []struct {
		name    string
		decide  func(t *testing.T, w *writeFixture, id int64)
		status  string
		wantKey string // the extra key the result carries ("" = none)
	}{
		{"applied", func(t *testing.T, w *writeFixture, id int64) { w.approveAndApply(t, id) }, "applied", "result"},
		{"rejected", func(t *testing.T, w *writeFixture, id int64) { w.transition(t, id, "pending", "rejected", "") }, "rejected", ""},
		{"failed", func(t *testing.T, w *writeFixture, id int64) {
			w.transition(t, id, "pending", "approved", "")
			w.transition(t, id, "approved", "failed", "the remote side refused")
		}, "failed", "error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWriteFixture(t)
			runID, actionID := w.startWaiting(t, w.seedWrite(t, []string{"tool:create_target"}, "", waitScript))
			tc.decide(t, w, actionID)
			r := w.finishWait(t, runID)
			out := summaryObject(t, r)
			if out["status"] != tc.status || idOf(t, out) != actionID || r.WaitingReason != "" {
				t.Fatalf("script got %v, waiting_reason %q; want status %s for %d", out, r.WaitingReason, tc.status, actionID)
			}
			if _, has := out[tc.wantKey]; tc.wantKey != "" && !has {
				t.Fatalf("script got %v; want a %q key", out, tc.wantKey)
			}
			if tc.status == "failed" && out["error"] != "the remote side refused" {
				t.Fatalf("error = %v; want the row's error", out["error"])
			}
			wantStep(t, w.toolStep(t, runID), tc.status, actionID, false)
		})
	}
}

func TestToolWait_PauseExcludedFromActiveTime(t *testing.T) {
	w := newWriteFixture(t)
	runID, actionID := w.startWaiting(t, w.seedWrite(t, []string{"tool:create_target"}, "budget:\n  minutes: 1\n", waitScript))
	w.clock.Advance(10 * time.Minute)
	w.approveAndApply(t, actionID)
	r := w.finishWait(t, runID)
	if r.ActiveMS >= time.Minute.Milliseconds() {
		t.Fatalf("active_ms = %d; want the 10 minutes of waiting excluded (< 60000)", r.ActiveMS)
	}
}

func TestToolWait_ExpiresAfterPauseTimeout(t *testing.T) {
	w := newWriteFixture(t)
	runID, actionID := w.startWaiting(t, w.seedWrite(t, []string{"tool:create_target"}, "pause_timeout_hours: 1\n", waitScript))
	w.clock.Advance(61 * time.Minute)
	w.e.Wake()
	w.e.Wait()
	w.wantRun(t, runID, db.RunExpired, db.ErrKindExpired)
	if row, err := w.d.GetAgentAction(actionID); err != nil || row.Status != "pending" {
		t.Fatalf("row = %+v, %v; want still pending", row, err)
	}
}

func TestToolWait_CancelLeavesProposalPending(t *testing.T) {
	w := newWriteFixture(t)
	runID, actionID := w.startWaiting(t, w.seedWrite(t, []string{"tool:create_target"}, "", waitScript))
	if ok, err := w.d.CancelAutomationRun(runID, w.clock.Now()); err != nil || !ok {
		t.Fatalf("cancel = (%v, %v)", ok, err)
	}
	w.e.Wake()
	w.e.Wait()
	w.wantRun(t, runID, db.RunCancelled, db.ErrKindCancelled)
	if row, err := w.d.GetAgentAction(actionID); err != nil || row.Status != "pending" {
		t.Fatalf("row = %+v, %v; want still pending", row, err)
	}
}

// runRowDump renders run id's automation_runs row and its steps, every
// column, byte for byte.
func (w *writeFixture) runRowDump(t *testing.T, id int64) string {
	t.Helper()
	var out strings.Builder
	for _, q := range []string{`SELECT * FROM automation_runs WHERE id = ?`, `SELECT * FROM automation_run_steps WHERE run_id = ? ORDER BY seq`} {
		rows, err := w.d.Query(q, id)
		if err != nil {
			t.Fatal(err)
		}
		cols, err := rows.Columns()
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				t.Fatal(err)
			}
			fmt.Fprintf(&out, "%v\n", vals)
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		_ = rows.Close()
	}
	return out.String()
}

func TestToolWait_ApproveAfterRunEndedChangesNoRun(t *testing.T) {
	w := newWriteFixture(t)
	runID, actionID := w.startWaiting(t, w.seedWrite(t, []string{"tool:create_target"}, "pause_timeout_hours: 1\n", waitScript))
	w.clock.Advance(61 * time.Minute)
	w.e.Wake()
	w.e.Wait()
	w.wantRun(t, runID, db.RunExpired, db.ErrKindExpired)
	before := w.runRowDump(t, runID)
	w.approveAndApply(t, actionID)
	if row, err := w.d.GetAgentAction(actionID); err != nil || row.Status != "applied" {
		t.Fatalf("row = %+v, %v; want applied", row, err)
	}
	if after := w.runRowDump(t, runID); after != before {
		t.Fatalf("the run changed after a late approval:\nbefore %s\nafter  %s", before, after)
	}
}

func TestAuto12_DryRunWriteNeverReachesRegistry(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWrite(t, []string{"tool:create_target"}, "", `return JSON.stringify([
		tool("create_target", {text: "first draft"}),
		tool("create_target", {text: "second draft"}, {wait: true})])`)
	id := w.enqueue(t, a, db.TriggerDryRun)
	r, err := w.e.ExecuteInline(context.Background(), id)
	if err != nil || r.Status != db.RunSucceeded {
		t.Fatalf("ExecuteInline = %+v, %v; want succeeded", r, err)
	}
	if r.Summary != `[{"status":"dry_run"},{"status":"dry_run"}]` {
		t.Fatalf("script got %s; want two dry_run results", r.Summary)
	}
	if rows := w.actions(t); len(rows) != 0 {
		t.Fatalf("agent_actions = %+v; want none in a dry run", rows)
	}
	steps := w.steps(t, id)
	if len(steps) != 2 {
		t.Fatalf("steps = %v; want two", stepStatusesOf(steps))
	}
	for i, want := range []string{"first draft", "second draft"} {
		s := steps[i]
		if s.Status != automations.StepDryRun || s.ActionID != 0 {
			t.Fatalf("step %d = %s action %d; want dry_run, no action", i, s.Status, s.ActionID)
		}
		mustContain(t, "dry-run step summary", s.ResultSummary, want)
	}
}

func TestToolWrite_UnknownOptionIsValidationError(t *testing.T) {
	for _, opts := range []string{`{wait: true, retries: 2}`, `{wait: "yes"}`, `[true]`, `"wait"`} {
		t.Run(opts, func(t *testing.T) {
			r := mustReturn(t, `try { tool("create_target", {text: "x"}, `+opts+`); return "called" } catch (e) { return e.name }`,
				sdkCase{perms: []string{"tool:create_target"}}, "ValidationError")
			if p := r.reg.ProposedCalls(); len(p) != 0 {
				t.Fatalf("proposals = %+v; want none", p)
			}
		})
	}
}

// TestToolWrite_ReceiptAndErrorMapping: an inline apply that failed is a
// failed result and step; a registry ValidationError is a ValidationError,
// a workbench automation's write (until P5) NotAvailable, any other registry
// failure a ToolError, and nothing is retried.
func TestToolWrite_ReceiptAndErrorMapping(t *testing.T) {
	cases := []struct {
		name    string
		receipt *tools.Receipt
		err     error
		want    string
		step    string
	}{
		{name: "failed apply", receipt: &tools.Receipt{ActionID: 9, Status: "failed", Error: "boom"},
			want: `{"error":"boom","id":9,"status":"failed"}`, step: automations.StepFailed},
		{name: "validation", err: &tools.ValidationError{Msg: "text is required"},
			want: "ValidationError|text is required", step: automations.StepError},
		{name: "workbench automation", err: fmt.Errorf("%w: workbench 3's automation cannot write yet", tools.ErrWorkbenchAutomationWrite),
			want: "NotAvailable|create_target: workbench automations get writes in a later phase: workbench 3's automation cannot write yet",
			step: automations.StepError},
		{name: "other", err: tools.ErrNotWritable,
			want: "ToolError|create_target: tool is not a write tool", step: automations.StepError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := fakeTools()
			if tc.receipt != nil {
				reg.ProposeReceipts = map[string]tools.Receipt{"create_target": *tc.receipt}
			}
			if tc.err != nil {
				reg.ProposeErrors = map[string]error{"create_target": tc.err}
			}
			r := mustReturn(t, `try { return JSON.stringify(tool("create_target", {text: "x"})) } catch (e) { return e.name + "|" + e.message }`,
				sdkCase{perms: []string{"tool:create_target"}, reg: reg}, tc.want)
			if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != tc.step || len(reg.ProposedCalls()) != 1 {
				t.Fatalf("steps = %v, proposals %d; want one %s step and one proposal", stepStatuses(steps), len(reg.ProposedCalls()), tc.step)
			}
		})
	}
}

// TestToolWrite_BindingCarriesTheRun: the proposal is made under the run's
// automation binding, never DirectApply.
func TestToolWrite_BindingCarriesTheRun(t *testing.T) {
	r := mustReturn(t, `return tool("create_target", {text: "x"}).status`, sdkCase{perms: []string{"tool:create_target"}}, "proposed")
	p := r.reg.ProposedCalls()
	if len(p) != 1 {
		t.Fatalf("proposals = %+v; want one", p)
	}
	b := p[0].Binding
	if b.Surface != tools.AutomationSurface || b.ContextType != tools.AutomationContextType || b.ContextID != "42" ||
		b.AutomationRunID != 42 || b.DirectApply || b.AutomationAgent {
		t.Fatalf("binding = %+v; want the automation binding of run 42", b)
	}
}

// TestToolWait_WithoutExecutorIsNotAvailable: a {wait:true} outside the
// executor (no Waiter) throws NotAvailable before anything is proposed.
func TestToolWait_WithoutExecutorIsNotAvailable(t *testing.T) {
	r := mustReturn(t, `try { tool("create_target", {text: "x"}, {wait: true}); return "called" } catch (e) { return e.name }`,
		sdkCase{perms: []string{"tool:create_target"}}, "NotAvailable")
	if p := r.reg.ProposedCalls(); len(p) != 0 {
		t.Fatalf("proposals = %+v; want none", p)
	}
}

// TestToolWrite_NonStringReasonReachesRegistryUnchanged: only an absent,
// null or blank reason is defaulted; a non-string one is the registry's to
// refuse, never silently replaced.
func TestToolWrite_NonStringReasonReachesRegistryUnchanged(t *testing.T) {
	r := mustReturn(t, `return tool("create_target", {text: "x", reason: 5}).status`, sdkCase{perms: []string{"tool:create_target"}}, "proposed")
	p := r.reg.ProposedCalls()
	if len(p) != 1 || !strings.Contains(string(p[0].Args), `"reason":5`) {
		t.Fatalf("proposals = %+v; want the args with reason 5 unchanged", p)
	}
}

// logWaits records every move of a run or a step to waiting in wait_log.
func (w *writeFixture) logWaits(t *testing.T) {
	t.Helper()
	for _, q := range []string{
		`CREATE TABLE wait_log (what TEXT NOT NULL)`,
		`CREATE TRIGGER log_run_wait AFTER UPDATE OF status ON automation_runs WHEN NEW.status = 'waiting'
			BEGIN INSERT INTO wait_log VALUES ('run'); END`,
		`CREATE TRIGGER log_step_wait AFTER UPDATE OF status ON automation_run_steps WHEN NEW.status = 'waiting'
			BEGIN INSERT INTO wait_log VALUES ('step'); END`,
	} {
		if _, err := w.d.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
}

// TestToolWait_AutoGrantReturnsAtOnce: {wait:true} on a write an active
// grant applied inline returns the applied result at once — neither the run
// nor the step ever goes waiting.
func TestToolWait_AutoGrantReturnsAtOnce(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWrite(t, []string{"tool:create_target"}, "", waitScript)
	if err := w.d.SetAutomationToolGrant(a.ID, "create_target", a.ApprovalHash, exStart); err != nil {
		t.Fatal(err)
	}
	w.logWaits(t)
	r := w.runToEnd(t, a)
	row := w.onlyAction(t)
	if out := summaryObject(t, r); r.Status != db.RunSucceeded || out["status"] != "applied" || idOf(t, out) != row.ID {
		t.Fatalf("run %s, script got %s; want succeeded with applied #%d", r.Status, r.Summary, row.ID)
	}
	if n := w.count(t, "wait_log"); n != 0 {
		t.Fatalf("wait_log rows = %d; want no run or step ever waiting", n)
	}
	wantStep(t, w.toolStep(t, r.ID), automations.StepApplied, row.ID, true)
}

// TestToolWait_DryRunInMemoryAnswersDryRun: the in-memory dry run has no
// Waiter and no DB; a {wait:true} write still answers {status:"dry_run"}
// (never NotAvailable) and proposes nothing.
func TestToolWait_DryRunInMemoryAnswersDryRun(t *testing.T) {
	text := strings.NewReplacer("PERMS", "  - tool:create_target\n", "EXTRA", "",
		"SCRIPT", `var r = tool("create_target", {text: "x"}, {wait: true});
if (r.status !== "dry_run") throw new Error(JSON.stringify(r));
return 1`).Replace(writeRecipe)
	rc, err := automations.ParseRecipe("mail", []byte(text), automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatal(err)
	}
	reg := fakeTools()
	rep, err := automations.DryRunInMemory(context.Background(),
		automations.Backends{Registry: reg, Generator: &automationstest.FakeGenerator{}}, rc, automations.DryRunOptions{})
	if err != nil || rep.Status != db.RunSucceeded {
		t.Fatalf("DryRunInMemory = %+v, %v; want succeeded", rep, err)
	}
	if len(rep.Steps) != 1 || rep.Steps[0].Status != automations.StepDryRun || len(reg.ProposedCalls()) != 0 {
		t.Fatalf("steps = %v, proposals %d; want one dry_run step and none", stepStatuses(rep.Steps), len(reg.ProposedCalls()))
	}
}

// TestToolWait_MarkFailureKeepsActionLink: when the journal cannot mark the
// step waiting, the step closes as an error that still names the proposal,
// and the proposal stays pending.
func TestToolWait_MarkFailureKeepsActionLink(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWrite(t, []string{"tool:create_target"}, "", waitScript)
	if _, err := w.d.Exec(`CREATE TRIGGER refuse_step_wait BEFORE UPDATE OF status ON automation_run_steps
		WHEN NEW.status = 'waiting' BEGIN SELECT RAISE(ABORT, 'the journal refused'); END`); err != nil {
		t.Fatal(err)
	}
	r := w.runToEnd(t, a)
	row := w.onlyAction(t)
	if r.Status != db.RunFailed || row.Status != "pending" {
		t.Fatalf("run %s (%s), row %s; want a failed run and a pending row", r.Status, r.Error, row.Status)
	}
	s := w.toolStep(t, r.ID)
	if s.Status != automations.StepError || s.ActionID != row.ID || s.FinishedAt == nil {
		t.Fatalf("step = %s action %d; want a closed error step linked to #%d", s.Status, s.ActionID, row.ID)
	}
	mustContain(t, "step error", s.Error, fmt.Sprintf("proposal #%d is recorded", row.ID))
}

// TestToolWait_OwnerEditReachesResult: the owner approves the waited-on
// proposal with an edit; the script's result is what the edited args applied.
func TestToolWait_OwnerEditReachesResult(t *testing.T) {
	w := newWriteFixture(t)
	runID, actionID := w.startWaiting(t, w.seedWrite(t, []string{"tool:edit_note"}, "",
		`return JSON.stringify(tool("edit_note", {text: "draft", reason: "scheduled"}, {wait: true}))`))
	if ok, err := w.reg.Approve(context.Background(), actionID, json.RawMessage(`{"text":"edited by the owner"}`)); err != nil || !ok {
		t.Fatalf("approve with edit = (%v, %v)", ok, err)
	}
	if _, err := w.reg.Apply(context.Background(), actionID); err != nil {
		t.Fatalf("apply: %v", err)
	}
	out := summaryObject(t, w.finishWait(t, runID))
	res, _ := out["result"].(map[string]any)
	if out["status"] != "applied" || res["text"] != "edited by the owner" {
		t.Fatalf("script got %v; want applied with the edited text", out)
	}
}
