package automations_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// outputRecipe is writeRecipe with OUTPUTS (the outputs list) replaced too.
const outputRecipe = "---\nname: New mail summary\ntrigger:\n  manual: true\npermissions:\nPERMS" +
	"outputs: [OUTPUTS]\n---\nOutputs for the P2 output tests.\n\n```js\nSCRIPT\n```\n"

// slackArgs is what the fake send_slack_message write tool takes.
type slackArgs struct {
	AccountID int64  `json:"account_id"`
	Channel   string `json:"channel"`
	Text      string `json:"text"`
	Reason    string `json:"reason"`
}

// fakeSlackSend is an External send_slack_message stand-in on the automation
// surface (the real one needs Slack accounts and a sender).
func fakeSlackSend(t *testing.T, surfaces ...string) *tools.Tool {
	t.Helper()
	schema, err := jsonschema.For[slackArgs](nil)
	if err != nil {
		t.Fatal(err)
	}
	return &tools.Tool{
		Name: "send_slack_message", Description: "fake slack send", InputSchema: schema, Access: tools.AccessWrite,
		External: true, Surfaces: surfaces,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(context.Context, *db.DB, tools.Call) (any, error) {
			return map[string]any{"sent": true}, nil
		},
	}
}

// newOutputFixture is the write fixture's executor over a real registry with
// create_target and a fake External send_slack_message.
func newOutputFixture(t *testing.T) *writeFixture {
	t.Helper()
	return newOutputFixtureSlackOn(t, tools.AutomationSurface)
}

// newOutputFixtureSlackOn is newOutputFixture with send_slack_message
// offered on surfaces only.
func newOutputFixtureSlackOn(t *testing.T, surfaces ...string) *writeFixture {
	t.Helper()
	w := &writeFixture{}
	w.exFixture = newExFixture(t, exOpts{fileDB: true, registry: func(d *db.DB) automations.ToolRegistry {
		w.reg = tools.New(d)
		for _, tl := range []*tools.Tool{tools.NewCreateTarget(), fakeSlackSend(t, surfaces...)} {
			if err := w.reg.Register(tl); err != nil {
				t.Fatalf("register %s: %v", tl.Name, err)
			}
		}
		return w.reg
	}})
	if _, err := w.d.Exec(`INSERT INTO slack_accounts (id, label, team_domain) VALUES (1, 'work', 'acme-work'), (2, 'home', 'acme-home')`); err != nil {
		t.Fatalf("seeding slack accounts: %v", err)
	}
	return w
}

// slackWork is the permission that covers the fixture's work account (id 1).
var slackWork = []string{"slack:write@work"}

// seedOutput indexes, confirms and enables slug with perms, outputs and script.
func (w *writeFixture) seedOutput(t *testing.T, slug string, perms []string, outputs, script string) db.Automation {
	t.Helper()
	var lines strings.Builder
	for _, p := range perms {
		lines.WriteString("  - " + p + "\n")
	}
	text := strings.NewReplacer("PERMS", lines.String(), "OUTPUTS", outputs, "SCRIPT", script).Replace(outputRecipe)
	return w.seedText(t, slug, text, false)
}

// outputStep is run id's one output step named name.
func (w *writeFixture) outputStep(t *testing.T, id int64, name string) db.AutomationRunStep {
	t.Helper()
	var found []db.AutomationRunStep
	for _, s := range w.steps(t, id) {
		if s.Kind == automations.StepKindOutput && s.Name == name {
			found = append(found, s)
		}
	}
	if len(found) != 1 {
		t.Fatalf("output steps %q = %v; want one", name, stepStatusesOf(found))
	}
	return found[0]
}

func (w *writeFixture) outputCount(t *testing.T, kind string) int {
	t.Helper()
	var n int
	if err := w.d.QueryRow(`SELECT COUNT(*) FROM automation_outputs WHERE kind = ?`, kind).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestOutput_BriefingBufferedAndCommittedOnSuccess(t *testing.T) {
	w := newOutputFixture(t)
	ok := w.runToEnd(t, w.seedOutput(t, "brief", []string{"llm:light"}, "briefing",
		`output.briefing({title: "Mail", body: "3 new from acme"}); return "ok"`))
	if ok.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", ok.Status, ok.ErrorKind, ok.Error)
	}
	rows, err := w.d.ListAutomationOutputs("briefing", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Title != "Mail" || rows[0].Body != "3 new from acme" || rows[0].RunID != ok.ID {
		t.Fatalf("briefing outputs = %+v; want one row of run %d", rows, ok.ID)
	}
	if s := w.outputStep(t, ok.ID, "briefing"); s.Permission != "output:briefing" {
		t.Fatalf("step permission = %q; want output:briefing", s.Permission)
	}

	failed := w.runToEnd(t, w.seedOutput(t, "brief-fails", []string{"llm:light"}, "briefing",
		`output.briefing({title: "Mail", body: "lost"}); throw new Error("boom")`))
	if failed.Status != db.RunFailed {
		t.Fatalf("run = %s; want failed", failed.Status)
	}
	if n := w.outputCount(t, "briefing"); n != 1 {
		t.Fatalf("briefing outputs = %d; want only the succeeded run's one (AUTO-04)", n)
	}
}

func TestOutput_TargetGateIsOutputsNotTool(t *testing.T) {
	w := newOutputFixture(t)
	r := w.runToEnd(t, w.seedOutput(t, "gate-outputs", []string{"llm:light"}, "target",
		`return JSON.stringify(output.target({text: "Reply to acme"}))`))
	if r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	row := w.onlyAction(t)
	if row.Tool != "create_target" || row.Status != "pending" || row.ContextType != tools.AutomationContextType ||
		row.ContextID != fmt.Sprint(r.ID) || row.Reason != "⚙ New mail summary · run #"+fmt.Sprint(r.ID) {
		t.Fatalf("row = %+v; want a pending create_target of run %d with the default reason", row, r.ID)
	}
	mustContain(t, "create_target args", row.ArgsJSON, `"text":"Reply to acme"`)
	if out := summaryObject(t, r); out["status"] != "proposed" || idOf(t, out) != row.ID {
		t.Fatalf("script got %v; want {status: proposed, id: %d}", out, row.ID)
	}
	s := w.outputStep(t, r.ID, "target")
	wantStep(t, s, automations.StepProposed, row.ID, false)
	if s.Permission != "output:target" {
		t.Fatalf("step permission = %q; want output:target", s.Permission)
	}

	denied := w.runToEnd(t, w.seedOutput(t, "gate-tool", []string{"tool:create_target"}, "inbox",
		`try { output.target({text: "x"}); return "called" } catch (e) { return e.name + "|" + e.needed }`))
	if denied.Summary != "PermissionDenied|output:target" {
		t.Fatalf("summary = %q; want PermissionDenied|output:target", denied.Summary)
	}
	if rows := w.actions(t); len(rows) != 1 {
		t.Fatalf("agent_actions = %d rows; want no new row after the denial", len(rows))
	}
}

const slackOutputScript = `return JSON.stringify(output.slack({account_id: 1, channel: "#general", text: "Daily mail summary"}))`

func TestOutput_SlackIsAProposalUnlessGranted(t *testing.T) {
	t.Run("no grant", func(t *testing.T) {
		w := newOutputFixture(t)
		r := w.runToEnd(t, w.seedOutput(t, "slack", slackWork, "slack", slackOutputScript))
		row := w.onlyAction(t)
		if row.Tool != "send_slack_message" || row.Status != "pending" || row.TrustAtCreate != "ask" {
			t.Fatalf("row = %+v; want a pending send_slack_message, ask", row)
		}
		mustContain(t, "send_slack_message args", row.ArgsJSON, `"channel":"#general"`)
		mustContain(t, "send_slack_message args", row.ArgsJSON, `"text":"Daily mail summary"`)
		s := w.outputStep(t, r.ID, "slack")
		wantStep(t, s, automations.StepProposed, row.ID, false)
		if s.Permission != "output:slack, slack:write@work" {
			t.Fatalf("step permission = %q; want output:slack, slack:write@work", s.Permission)
		}
	})
	t.Run("active grant", func(t *testing.T) {
		w := newOutputFixture(t)
		a := w.seedOutput(t, "slack", slackWork, "slack", slackOutputScript)
		if err := w.d.SetAutomationToolGrant(a.ID, "send_slack_message", a.ApprovalHash, exStart); err != nil {
			t.Fatal(err)
		}
		r := w.runToEnd(t, a)
		row := w.onlyAction(t)
		if row.Status != "applied" || row.TrustAtCreate != "execute" {
			t.Fatalf("row = %+v; want applied, execute", row)
		}
		mustContain(t, "send_slack_message args", row.ArgsJSON, `"text":"Daily mail summary"`)
		if out := summaryObject(t, r); out["status"] != "applied" || out["result"] == nil {
			t.Fatalf("script got %v; want {status: applied, id, result}", out)
		}
		wantStep(t, w.outputStep(t, r.ID, "slack"), automations.StepApplied, row.ID, true)
	})
}

func TestOutput_P2KindsDryRun(t *testing.T) {
	w := newOutputFixture(t)
	a := w.seedOutput(t, "dry", slackWork, "briefing, target, slack", `return JSON.stringify([
		output.briefing({title: "Mail", body: "3 new"}),
		output.target({text: "Reply to acme"}),
		output.slack({account_id: 1, channel: "#general", text: "hi"})])`)
	id := w.enqueue(t, a, db.TriggerDryRun)
	r, err := w.e.ExecuteInline(context.Background(), id)
	if err != nil || r.Status != db.RunSucceeded {
		t.Fatalf("ExecuteInline = %+v, %v; want succeeded", r, err)
	}
	if r.Summary != `[{"status":"dry_run"},{"status":"dry_run"},{"status":"dry_run"}]` {
		t.Fatalf("script got %s; want three dry_run results", r.Summary)
	}
	if rows := w.actions(t); len(rows) != 0 {
		t.Fatalf("agent_actions = %+v; want none in a dry run", rows)
	}
	if n := w.count(t, "automation_outputs"); n != 0 {
		t.Fatalf("automation_outputs = %d; want none committed by a dry run", n)
	}
	wouldBe := map[string]string{"briefing": `"body":"3 new"`, "target": `"text":"Reply to acme"`, "slack": `"text":"hi"`}
	for _, kind := range []string{"briefing", "target", "slack"} {
		s := w.outputStep(t, id, kind)
		if s.Status != automations.StepDryRun || s.ActionID != 0 {
			t.Fatalf("%s step = %s action %d; want dry_run, no action", kind, s.Status, s.ActionID)
		}
		mustContain(t, kind+" dry-run step summary", s.ResultSummary, wouldBe[kind])
	}
}

func TestOutput_ToolOffTheAutomationSurfaceIsNotAvailable(t *testing.T) {
	for _, trigger := range []string{db.TriggerManual, db.TriggerDryRun} {
		t.Run(trigger, func(t *testing.T) {
			w := newOutputFixtureSlackOn(t, "main")
			a := w.seedOutput(t, "off-surface", slackWork, "slack",
				`try { output.slack({channel: "#general", text: "hi"}); return "called" } catch (e) { return e.name }`)
			id := w.enqueue(t, a, trigger)
			if trigger == db.TriggerDryRun {
				if _, err := w.e.ExecuteInline(context.Background(), id); err != nil {
					t.Fatalf("ExecuteInline: %v", err)
				}
			} else {
				w.step(t, 1)
			}
			if r := w.run(t, id); r.Summary != automations.ErrNameNotAvailable {
				t.Fatalf("run = %s, summary %q; want summary %s", r.Status, r.Summary, automations.ErrNameNotAvailable)
			}
			if rows := w.actions(t); len(rows) != 0 {
				t.Fatalf("agent_actions = %+v; want none", rows)
			}
		})
	}
}

// slackScopeCase is one output.slack scope check (D28): the run's
// permissions and call args, and either the denial's needed scope (with the
// step error's expected cause, "" for a plain denial) or "" for a proposal.
type slackScopeCase struct {
	name, args, needed, cause string
	perms                     []string
}

const slackScopeScript = `try { return JSON.stringify(output.slack(ARGS)) } catch (e) { return e.name + "|" + e.needed }`

// checkSlackScope runs c under trigger and checks the summary, the
// agent_actions rows and the slack step (AUTO-01: a denial is a denied step
// naming the needed scope, with no would-be summary).
func checkSlackScope(t *testing.T, c slackScopeCase, trigger string) {
	t.Helper()
	w := newOutputFixture(t)
	a := w.seedOutput(t, "scope", c.perms, "slack", strings.Replace(slackScopeScript, "ARGS", c.args, 1))
	id := w.enqueue(t, a, trigger)
	if trigger == db.TriggerDryRun {
		if _, err := w.e.ExecuteInline(context.Background(), id); err != nil {
			t.Fatalf("ExecuteInline: %v", err)
		}
	} else {
		w.step(t, 1)
	}
	r, s := w.run(t, id), w.outputStep(t, id, "slack")
	if c.needed == "" {
		if !strings.HasPrefix(r.Summary, `{"id":`) || len(w.actions(t)) != 1 || s.Status != automations.StepProposed {
			t.Fatalf("summary %q, step %s; want one proposal", r.Summary, s.Status)
		}
		return
	}
	if r.Summary != "PermissionDenied|"+c.needed {
		t.Fatalf("summary = %q; want PermissionDenied|%s", r.Summary, c.needed)
	}
	if rows := w.actions(t); len(rows) != 0 {
		t.Fatalf("agent_actions = %+v; want none", rows)
	}
	if s.Status != automations.StepDenied || s.Permission != c.needed || s.ResultSummary != "" {
		t.Fatalf("step = %s permission %q summary %q; want denied, %s, no summary", s.Status, s.Permission, s.ResultSummary, c.needed)
	}
	if c.cause != "" {
		mustContain(t, "denied step error", s.Error, c.cause)
	}
}

func TestOutput_SlackNeedsSlackWriteScope(t *testing.T) {
	cases := []slackScopeCase{
		{name: "outputs slack without slack:write", perms: []string{"llm:light"}, args: `{channel: "#general", text: "hi"}`, needed: "slack:write@*"},
		{name: "slack:write@work, work account", perms: slackWork, args: `{account_id: 1, channel: "#general", text: "hi"}`},
		{name: "slack:write@work, home account", perms: slackWork, args: `{account_id: 2, channel: "#general", text: "hi"}`, needed: "slack:write@home"},
		{name: "unknown account keeps its cause", perms: slackWork, args: `{account_id: 99, channel: "#general", text: "hi"}`,
			needed: "slack:write@*", cause: "slack account 99"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { checkSlackScope(t, c, db.TriggerManual) })
	}
}

func TestOutput_SlackScopeDeniedInDryRun(t *testing.T) {
	checkSlackScope(t, slackScopeCase{perms: []string{"llm:light"}, args: `{account_id: 1, channel: "#general", text: "hi"}`,
		needed: "slack:write@work"}, db.TriggerDryRun)
}

func TestOutput_ToolOutputArgumentShape(t *testing.T) {
	cases := []struct{ name, call string }{
		{"second argument", `output.target({text: "x"}, {wait: true})`},
		{"not an object", `output.target("x")`},
		{"no argument", `output.slack()`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newOutputFixture(t)
			r := w.runToEnd(t, w.seedOutput(t, "shape", []string{"llm:light"}, "target, slack",
				`try { `+c.call+`; return "called" } catch (e) { return e.name }`))
			if r.Summary != automations.ErrNameValidation {
				t.Fatalf("summary = %q; want %s", r.Summary, automations.ErrNameValidation)
			}
			if rows := w.actions(t); len(rows) != 0 {
				t.Fatalf("agent_actions = %+v; want none", rows)
			}
		})
	}
}

func TestRegisterOutputKind_UnknownKindStillRefused(t *testing.T) {
	mustReturn(t, `return [typeof output.email, typeof output.briefing, typeof output.target, typeof output.slack].join("|")`,
		sdkCase{}, "undefined|function|function|function")
	mustReturn(t, `try { output.email({title: "t", body: "b"}); return "called" } catch (e) { return e.name }`,
		sdkCase{outputs: []string{"inbox"}}, "TypeError")
}

// seedWorkbenchOutput indexes a workbench automation (a real workbench and
// its recipe folder) with perms, outputs and script, then confirms and
// enables it.
func (w *writeFixture) seedWorkbenchOutput(t *testing.T, slug string, perms []string, outputs, script string) db.Automation {
	t.Helper()
	folder, err := db.ResolveWorkbenchFolder(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	wb, err := w.d.CreateWorkbench("acme", folder)
	if err != nil {
		t.Fatal(err)
	}
	var lines strings.Builder
	for _, p := range perms {
		lines.WriteString("  - " + p + "\n")
	}
	text := strings.NewReplacer("PERMS", lines.String(), "OUTPUTS", outputs, "SCRIPT", script).Replace(outputRecipe)
	dir := automations.WorkbenchDir(folder)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, slug+".md"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	scope := automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: wb}
	if _, err := w.ix.RescanFolder(context.Background(), scope, dir); err != nil {
		t.Fatalf("rescan: %v", err)
	}
	a, err := w.d.GetAutomationBySlug("workbench", wb, slug)
	if err != nil {
		t.Fatalf("get %s: %v", slug, err)
	}
	if a.ParseError != "" {
		t.Fatalf("%s does not parse: %s", slug, a.ParseError)
	}
	if err := w.d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
		t.Fatalf("confirm %s: %v", slug, err)
	}
	if err := w.d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
		t.Fatalf("enable %s: %v", slug, err)
	}
	if a, err = w.d.GetAutomation(a.ID); err != nil {
		t.Fatal(err)
	}
	return *a
}

// Until P5 a workbench automation's run may not write: through the real
// registry, a live run's output.target and tool() write throw NotAvailable
// and record no agent_actions row, and a dry run refuses the same writes
// rather than report {status: "dry_run"}. Each refused call is one error
// step without an action.
func TestWorkbenchAutomation_WritesNotAvailable(t *testing.T) {
	const script = `const out = [];
		for (const f of [() => output.target({text: "Reply to acme"}), () => tool("create_target", {text: "x"})]) {
			try { f(); out.push("called") } catch (e) { out.push(e.name) }
		}
		return out.join(",")`
	for _, trigger := range []string{db.TriggerManual, db.TriggerDryRun} {
		t.Run(trigger, func(t *testing.T) {
			w := newOutputFixture(t)
			a := w.seedWorkbenchOutput(t, "wb-writes", []string{"llm:light", "tool:create_target"}, "target", script)
			id := w.enqueue(t, a, trigger)
			r, err := w.e.ExecuteInline(context.Background(), id)
			if err != nil || r.Status != db.RunSucceeded {
				t.Fatalf("ExecuteInline = %+v, %v; want succeeded", r, err)
			}
			if r.Summary != "NotAvailable,NotAvailable" {
				t.Fatalf("script got %q; want both writes NotAvailable", r.Summary)
			}
			if rows := w.actions(t); len(rows) != 0 {
				t.Fatalf("agent_actions = %+v; want none", rows)
			}
			for _, s := range w.steps(t, id) {
				if s.Kind != automations.StepKindOutput && s.Kind != automations.StepKindTool {
					continue
				}
				if s.Status != automations.StepError || s.ActionID != 0 {
					t.Fatalf("%s %s step = %s action %d; want error, no action", s.Kind, s.Name, s.Status, s.ActionID)
				}
				mustContain(t, s.Name+" step error", s.Error, "workbench automations get writes in a later phase")
			}
		})
	}
}
