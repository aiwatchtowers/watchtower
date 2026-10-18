package automations_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

// The gallery templates (spec §15) installed and run end to end: the
// personal recipes read the seeded rows of testdata/template_fixtures through
// the real read tools; FakeGenerator answers llm().

// newTplFixture is an executor over a file DB seeded with the template
// fixtures, whose registry holds the real automation read tools.
func newTplFixture(t *testing.T, gen *automationstest.FakeGenerator) *exFixture {
	t.Helper()
	f := newExFixture(t, exOpts{fileDB: true, gen: gen, registry: func(d *db.DB) automations.ToolRegistry {
		reg := tools.New(d)
		all := append([]*tools.Tool{tools.NewListEmails(), tools.NewGetEmail()}, tools.AutomationReadTools()...)
		for _, tl := range append(all, tools.ReadTools()...) {
			if err := reg.Register(tl); err != nil {
				t.Fatalf("register %s: %v", tl.Name, err)
			}
		}
		return reg
	}})
	seedTemplateFixtures(t, f.d)
	return f
}

func seedTemplateFixtures(t *testing.T, d *db.DB) {
	t.Helper()
	sql, err := os.ReadFile(filepath.Join("testdata", "template_fixtures", "seed.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(string(sql)); err != nil {
		t.Fatalf("seeding the template fixtures: %v", err)
	}
}

// installTemplate renders the personal template name with params, indexes
// it, confirms and enables it.
func (f *exFixture) installTemplate(t *testing.T, name string, params map[string]string) db.Automation {
	t.Helper()
	files, err := automations.RenderTemplate(name, params)
	if err != nil {
		t.Fatal(err)
	}
	return f.seedText(t, name, string(files[name]), false)
}

// workEvent is the event_json of one gmail.new_messages event for the
// mailbox "work".
func workEvent(t *testing.T, cycle string) string {
	t.Helper()
	raw, err := json.Marshal(db.AutomationEventPayload{Cycles: []string{cycle},
		Events: []json.RawMessage{json.RawMessage(`{"type":"gmail.new_messages","account":"work","count":3}`)}, Count: 1})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// stepsLine renders a run's steps as kind(name):status, comma-separated.
func stepsLine(steps []db.AutomationRunStep) string {
	parts := make([]string, len(steps))
	for i, s := range steps {
		parts[i] = s.Kind + "(" + s.Name + "):" + s.Status
	}
	return strings.Join(parts, ",")
}

func (f *exFixture) stateDump(t *testing.T) string {
	t.Helper()
	state, _, _ := strings.Cut(f.dump(t), "\n")
	return state
}

// personalDryRun is one personal template's pinned dry-run journal.
type personalDryRun struct {
	name    string
	params  map[string]string
	event   bool
	steps   string
	toolArg map[string]string // tool step name → a substring of its args
	strong  int               // llm calls tagged automation.llm.strong
	read    []string          // seeded values the first llm() call's input carries
}

var personalDryRuns = []personalDryRun{
	{
		name: "new-mail-summary", event: true,
		steps:   "state(get):ok,tool(list_emails):ok,tool(list_emails):ok,llm(light):ok,output(inbox):dry_run,state(set):dry_run",
		toolArg: map[string]string{"list_emails": `"account":"work"`},
		read:    []string{"Deploy window", "Lunch", "Contract review"},
	},
	{
		name: "jira-state-report", params: map[string]string{"PROJECT": "PAY"},
		steps: "tool(list_jira_issues):ok,tool(get_jira_time_in_status):ok,llm(strong):ok,llm(light):ok," +
			"output(report):dry_run,output(briefing):dry_run",
		toolArg: map[string]string{"list_jira_issues": `"project":"PAY"`, "get_jira_time_in_status": `"project":"PAY"`},
		strong:  1,
		read:    []string{"PAY-1", "PAY-5", "Fraud check timeout"},
	},
	{
		name: "team-performance-report",
		steps: "tool(list_jira_issues):ok,tool(get_jira_time_in_status):ok,tool(list_people):ok," +
			"tool(list_messages):ok,tool(list_messages):ok,llm(strong):ok,output(report):dry_run",
		toolArg: map[string]string{"list_messages": `"person":"1:U1`},
		strong:  1,
		read:    []string{"PAY-4", "Drives the releases", "Payout retries are blocked on the fraud check"},
	},
}

// TestTemplates_DryRunE2E (spec §18): every gallery template, installed and
// dry-run, writes nothing outside its journal (AUTO-12) while its reads and
// llm() calls run for real.
func TestTemplates_DryRunE2E(t *testing.T) {
	for _, c := range personalDryRuns {
		t.Run(c.name, func(t *testing.T) { runPersonalDryRun(t, c) })
	}
	for _, slug := range workbenchRecipeSlugs {
		t.Run(slug, func(t *testing.T) { runWorkbenchDryRun(t, slug) })
	}
}

func runPersonalDryRun(t *testing.T, c personalDryRun) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- a summary"}, Usage: []digest.Usage{{InputTokens: 120, OutputTokens: 30}}}
	f := newTplFixture(t, gen)
	a := f.installTemplate(t, c.name, c.params)
	req := db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerDryRun}
	if c.event {
		req.EventJSON = workEvent(t, "c1")
	}
	id := f.enqueueReq(t, req)
	stateBefore := f.stateDump(t)

	r, err := f.e.ExecuteInline(context.Background(), id)
	wantDrySucceeded(t, r, err)
	steps := f.steps(t, id)
	if got := stepsLine(steps); got != c.steps {
		t.Fatalf("steps =\n  %s\nwant\n  %s", got, c.steps)
	}
	for _, s := range steps {
		if want, ok := c.toolArg[s.Name]; ok && s.Kind == automations.StepKindTool {
			mustContain(t, s.Name+" args", s.ArgsJSON, want)
		}
	}
	calls := gen.Snapshot()
	for _, want := range c.read {
		mustContain(t, "llm() input", calls[0].UserMessage, want)
	}
	strong := 0
	for _, call := range calls {
		if call.Source == automations.SourceLLMStrong {
			strong++
		}
	}
	if strong != c.strong {
		t.Fatalf("%d llm() calls tagged %s; want %d", strong, automations.SourceLLMStrong, c.strong)
	}
	if calls := gen.CallCount(); calls == 0 || r.InputTokens != int64(120*calls) || r.OutputTokens != int64(30*calls) {
		t.Fatalf("run tokens = %d+%d over %d llm() calls; want 120+30 each counted (AUTO-12)", r.InputTokens, r.OutputTokens, calls)
	}
	wantNothingWritten(t, f, r, stateBefore)
}

// workbenchDryRunSteps is each workbench recipe's pinned dry-run journal: an
// empty journal (a script that did nothing) must fail the guard. A dry-run
// shell() returns no output, so pr-review-rounds lists no pull request and
// starts no session step.
var workbenchDryRunSteps = map[string]string{
	// last_round and reviewed are read, then set (board #562: a round
	// starts at most MaxSessionCalls sessions and keeps the rest).
	"pr-review-rounds": "shell(shell):dry_run,state(get):ok,state(get):ok,state(set):dry_run,state(set):dry_run,output(report):dry_run",
	"release":          "shell(shell):dry_run,session(claude):dry_run,output(report):dry_run",
	"deploy-test":      "shell(shell):dry_run,session(claude):dry_run,output(report):dry_run",
	"deploy-stage":     "shell(shell):dry_run,session(claude):dry_run,output(report):dry_run",
}

func runWorkbenchDryRun(t *testing.T, slug string) {
	w := newWbE2E(t, automations.ShellResult{Stdout: prList})
	files, err := automations.RenderTemplate(templateOf(t, slug), nil)
	if err != nil {
		t.Fatal(err)
	}
	writeWorkbenchRecipe(t, w.folder, slug, string(files[slug]))
	rescanWorkbench(t, w.ix, w.wb, w.folder)
	id := w.enqueue(t, workbenchRow(t, w.d, w.wb, slug), db.TriggerDryRun)
	stateBefore := w.stateDump(t)

	r, err := w.e.ExecuteInline(context.Background(), id)
	wantDrySucceeded(t, r, err)
	if n := len(w.shell.Calls()); n != 0 {
		t.Fatalf("shell ran %d commands in a dry run", n)
	}
	steps := w.steps(t, id)
	if got := stepsLine(steps); got != workbenchDryRunSteps[slug] {
		t.Fatalf("steps =\n  %s\nwant\n  %s", got, workbenchDryRunSteps[slug])
	}
	for _, s := range steps {
		switch s.Kind {
		case automations.StepKindShell, automations.StepKindSession, automations.StepKindOutput:
			if s.Status != automations.StepDryRun {
				t.Fatalf("%s(%s) step is %s; want dry_run", s.Kind, s.Name, s.Status)
			}
		}
		if s.Status == automations.StepWaiting {
			t.Fatalf("%s(%s) step is waiting in a dry run", s.Kind, s.Name)
		}
	}
	for _, table := range []string{"terminal_sessions", "owner_asks"} {
		if n := w.count(t, table); n != 0 {
			t.Fatalf("%s = %d rows after a dry run; want none", table, n)
		}
	}
	wantNothingWritten(t, w.exFixture, r, stateBefore)
}

// templateOf is the gallery template that installs recipe slug.
func templateOf(t *testing.T, slug string) string {
	t.Helper()
	for _, tpl := range automations.Templates() {
		if slices.Contains(tpl.Files, slug) {
			return tpl.Name
		}
	}
	t.Fatalf("no template installs %s", slug)
	return ""
}

// wantNothingWritten checks AUTO-12 after a dry run: no agent_actions row,
// no output, automation_state as before — and the real llm() tokens counted
// on the run when it made llm() calls.
func wantNothingWritten(t *testing.T, f *exFixture, r *db.AutomationRun, stateBefore string) {
	t.Helper()
	for _, table := range []string{"agent_actions", "automation_outputs"} {
		if n := f.count(t, table); n != 0 {
			t.Fatalf("%s = %d rows after a dry run; want none", table, n)
		}
	}
	if got := f.stateDump(t); got != stateBefore {
		t.Fatalf("automation_state = %q after a dry run; want %q", got, stateBefore)
	}
	var stepTokens int64
	for _, s := range f.steps(t, r.ID) {
		if s.Kind == automations.StepKindLLM {
			stepTokens += s.InputTokens + s.OutputTokens
		}
	}
	if r.InputTokens+r.OutputTokens != stepTokens {
		t.Fatalf("run tokens = %d+%d; want the llm() steps' %d", r.InputTokens, r.OutputTokens, stepTokens)
	}
}

func wantDrySucceeded(t *testing.T, r *db.AutomationRun, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("dry run: %v", err)
	}
	if r.Status != db.RunSucceeded {
		t.Fatalf("dry run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
}
