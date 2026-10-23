package automations_test

import (
	"context"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

func parseExRecipe(t *testing.T, script string) *automations.Recipe {
	t.Helper()
	r, err := automations.ParseRecipe("draft", []byte(exRecipeText(script, "")), automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatalf("ParseRecipe: %v", err)
	}
	return r
}

var dryRunTables = []string{"automation_runs", "automation_run_steps", "automation_state", "automation_outputs", "agent_actions"}

func tableCounts(t *testing.T, d *db.DB) map[string]int {
	t.Helper()
	out := map[string]int{}
	for _, table := range dryRunTables {
		var n int
		if err := d.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
			t.Fatal(err)
		}
		out[table] = n
	}
	return out
}

func TestDryRunInMemory_WritesNoRows(t *testing.T) {
	d := db.OpenTestDB(t)
	gen := usageGen(10, 5)
	b := automations.Backends{DB: d, Generator: gen, Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart)}
	before := tableCounts(t, d)
	rep, err := automations.DryRunInMemory(context.Background(), b, parseExRecipe(t, `var s = llm("x");
tool("list_targets", {}); state.set("k", 1); output.inbox({title: "t", body: s}); log("done"); return 1`),
		automations.DryRunOptions{})
	if err != nil {
		t.Fatalf("DryRunInMemory: %v", err)
	}
	if rep.Status != db.RunSucceeded || rep.Error != "" {
		t.Fatalf("status %s (%s); want succeeded", rep.Status, rep.Error)
	}
	if got := stepStatusesOf(rep.Steps); got != "llm:ok,tool:ok,state:dry_run,output:dry_run,log:ok" {
		t.Fatalf("steps = %s", got)
	}
	if len(rep.Outputs) != 1 || rep.Outputs[0].Body != "done" || rep.InputTokens != 10 || rep.OutputTokens != 5 {
		t.Fatalf("report = %+v; want one would-be output and 10+5 tokens", rep)
	}
	for table, n := range tableCounts(t, d) {
		if n != before[table] {
			t.Errorf("%s rows %d → %d; want unchanged", table, before[table], n)
		}
	}
}

func TestDryRunInMemory_BudgetBound(t *testing.T) {
	gen := usageGen(20000, 10000)
	b := automations.Backends{Generator: gen, Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart)}
	rep, err := automations.DryRunInMemory(context.Background(), b, parseExRecipe(t, `llm("a"); llm("b"); llm("c"); return 1`),
		automations.DryRunOptions{Budget: automations.Budget{Tokens: 50000, Minutes: 5}})
	if err != nil {
		t.Fatalf("DryRunInMemory: %v", err)
	}
	if rep.Status != db.RunBudgetExceeded {
		t.Fatalf("status = %s (%s); want budget_exceeded", rep.Status, rep.Error)
	}
	if n := gen.CallCount(); n != 2 {
		t.Fatalf("generator calls = %d; want 2 (the third never reaches it)", n)
	}
}

// TestDryRunInMemory_StepResultIsJSON pins that a step's result_summary is
// the call's JSON, not the base64 of it (Env.Call's encodedResult).
func TestDryRunInMemory_StepResultIsJSON(t *testing.T) {
	b := automations.Backends{Generator: usageGen(10, 5), Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart)}
	rep, err := automations.DryRunInMemory(context.Background(), b, parseExRecipe(t, `tool("list_targets", {}); return llm("x")`),
		automations.DryRunOptions{})
	if err != nil {
		t.Fatalf("DryRunInMemory: %v", err)
	}
	if len(rep.Steps) != 2 {
		t.Fatalf("steps = %s; want tool and llm", stepStatusesOf(rep.Steps))
	}
	if got := rep.Steps[0].ResultSummary; got != `[{"id":7,"title":"Ship it"}]` {
		t.Errorf("tool step result = %q; want the JSON of the read", got)
	}
	if got := rep.Steps[1].ResultSummary; got != `"done"` {
		t.Errorf("llm step result = %q; want the JSON of the reply", got)
	}
}

func TestDryRunInMemory_AgentIsNotRun(t *testing.T) {
	d := db.OpenTestDB(t)
	gen := usageGen(10, 5)
	agent := &automationstest.FakeAgent{}
	b := automations.Backends{DB: d, Generator: gen, Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart), Agent: agent}
	text := strings.Replace(exRecipeText(`var r = agent("triage"); return r.status`, ""),
		"  - llm:light\n", "  - llm:light\n  - agent:run\n", 1)
	r, err := automations.ParseRecipe("draft", []byte(text), automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatal(err)
	}

	rep, err := automations.DryRunInMemory(context.Background(), b, r, automations.DryRunOptions{})
	if err != nil {
		t.Fatalf("DryRunInMemory: %v", err)
	}

	if rep.Status != db.RunSucceeded || stepStatusesOf(rep.Steps) != "agent:dry_run" {
		t.Fatalf("status %s (%s), steps %s; want one agent:dry_run step", rep.Status, rep.Error, stepStatusesOf(rep.Steps))
	}
	if n := len(agent.Requests()); n != 0 {
		t.Errorf("the runner was called %d times; want 0", n)
	}
	if rep.InputTokens+rep.OutputTokens != 0 {
		t.Errorf("tokens spent: %+v", rep)
	}
	if !strings.Contains(rep.Steps[0].ResultSummary, "not previewed in a draft") {
		t.Errorf("summary = %s; want the draft note", rep.Steps[0].ResultSummary)
	}
}

// draftMCPRecipe parses a draft granted mcp:github/* running script.
func draftMCPRecipe(t *testing.T, script string) *automations.Recipe {
	t.Helper()
	text := strings.Replace(exRecipeText(script, ""), "  - llm:light\n", "  - llm:light\n  - mcp:github/*\n", 1)
	r, err := automations.ParseRecipe("draft", []byte(text), automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// A draft's dry run never reaches a Quick Connection (ask #326): its script is
// chat-written, and even a read tool's arguments carry data to the server. It
// stops cleanly at the first mcp() call — a script that reads the result
// never fails on a stub — and the steps before it show as usual.
func TestDryRunInMemory_MCPIsNotCalled(t *testing.T) {
	m := &automationstest.FakeMCP{}
	b := automations.Backends{Generator: usageGen(10, 5), Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart), MCP: m}
	r := draftMCPRecipe(t, `tool("list_targets", {});
var r = mcp("github", "search_issues", {q: "secret"}); log("after"); return r.prs[0]`)

	rep, err := automations.DryRunInMemory(context.Background(), b, r, automations.DryRunOptions{})
	if err != nil {
		t.Fatalf("DryRunInMemory: %v", err)
	}

	if rep.Status != automations.DryRunStopped || rep.Error != automations.MCPDraftStop {
		t.Fatalf("status %s (%s); want stopped with the draft note", rep.Status, rep.Error)
	}
	if got := stepStatusesOf(rep.Steps); got != "tool:ok,mcp:dry_run" {
		t.Fatalf("steps = %s; want the read, then the stopped mcp step and nothing after", got)
	}
	if n := len(m.Calls()); n != 0 {
		t.Errorf("the Quick Connection was called %d times; want 0", n)
	}
	if !strings.Contains(rep.Steps[1].ResultSummary, "not made in a draft") {
		t.Errorf("summary = %s; want the draft note", rep.Steps[1].ResultSummary)
	}
}

// The manifest check precedes the draft stop: a tool the draft did not
// declare is PermissionDenied, as in a real run, and the script goes on.
func TestDryRunInMemory_MCPOutsideManifestIsDenied(t *testing.T) {
	m := &automationstest.FakeMCP{}
	b := automations.Backends{Generator: usageGen(10, 5), Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart), MCP: m}
	r := draftMCPRecipe(t, `try { mcp("gitlab", "list_prs"); return "called" } catch (e) { return e.name }`)

	rep, err := automations.DryRunInMemory(context.Background(), b, r, automations.DryRunOptions{})
	if err != nil {
		t.Fatalf("DryRunInMemory: %v", err)
	}

	if rep.Status != db.RunSucceeded || stepStatusesOf(rep.Steps) != "mcp:denied" {
		t.Fatalf("status %s (%s), steps %s; want succeeded with one denied mcp step", rep.Status, rep.Error, stepStatusesOf(rep.Steps))
	}
	if rep.Steps[0].Permission != "mcp:gitlab/list_prs" || len(m.Calls()) != 0 {
		t.Fatalf("step %+v, calls %d; want denied needing mcp:gitlab/list_prs and no call", rep.Steps[0], len(m.Calls()))
	}
}

// capturedPrompt is one prompt a capture dry run reported.
type capturedPrompt struct{ primitive, prompt string }

func captureDryRun(t *testing.T, b automations.Backends, r *automations.Recipe, stop bool) (*automations.DryRunReport, []capturedPrompt) {
	t.Helper()
	var got []capturedPrompt
	rep, err := automations.DryRunInMemory(context.Background(), b, r, automations.DryRunOptions{
		CapturePrompts:   func(primitive, prompt string) { got = append(got, capturedPrompt{primitive, prompt}) },
		StopAtModelCalls: stop,
	})
	if err != nil {
		t.Fatalf("DryRunInMemory: %v", err)
	}
	return rep, got
}

func TestDryRunCapture_ReportsPromptsAndWritesNothing(t *testing.T) {
	d := db.OpenTestDB(t)
	brief := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	scan := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	gen := usageGen(10, 5)
	b := automations.Backends{DB: d, Generator: gen, Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart),
		Primitives: map[string]automations.PrimitiveFunc{"brief.compose": brief.fn, "track.scan": scan.fn}}
	before := tableCounts(t, d)

	builtin, err := automations.ParseRecipe(testBuiltinID, []byte(builtinRecipeText(
		`const a = brief.compose({prompt: "P1"}).status; const b = brief.compose({prompt: "P2"}).status; return a + "," + b;`,
		"", "builtin:brief.compose")), automations.Scope{Kind: automations.ScopePersonal, BuiltinID: testBuiltinID})
	if err != nil {
		t.Fatal(err)
	}
	rep, got := captureDryRun(t, b, builtin, true)
	if rep.Status != db.RunSucceeded || len(got) != 2 || got[0] != (capturedPrompt{"brief.compose", "P1"}) ||
		got[1] != (capturedPrompt{"brief.compose", "P2"}) {
		t.Fatalf("built-in: report %s (%s), captured %+v", rep.Status, rep.Error, got)
	}
	if s := stepStatusesOf(rep.Steps); s != "llm:dry_run,llm:dry_run" {
		t.Errorf("built-in steps = %s", s)
	}

	watch, err := automations.ParseRecipe("watch", []byte(watchRecipeText(`return track.scan({instruction: "acme launch"}).status;`)),
		automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatal(err)
	}
	rep, got = captureDryRun(t, b, watch, true)
	if rep.Status != db.RunSucceeded || len(got) != 1 || got[0] != (capturedPrompt{"track.scan", "acme launch"}) {
		t.Fatalf("watch: report %s (%s), captured %+v", rep.Status, rep.Error, got)
	}
	if brief.count() != 0 || scan.count() != 0 || gen.CallCount() != 0 {
		t.Errorf("calls: brief %d, scan %d, model %d; want none", brief.count(), scan.count(), gen.CallCount())
	}
	for table, n := range tableCounts(t, d) {
		if n != before[table] {
			t.Errorf("%s rows %d → %d; want unchanged", table, before[table], n)
		}
	}
}

func TestDryRunCapture_StopsAtModelCall(t *testing.T) {
	scan := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	gen := usageGen(10, 5)
	b := automations.Backends{Generator: gen, Registry: fakeTools(), Clock: automationstest.NewFakeClock(exStart),
		Primitives: map[string]automations.PrimitiveFunc{"track.scan": scan.fn}}
	watch, err := automations.ParseRecipe("watch", []byte(watchRecipeText(
		`const instruction = llm("write the instruction"); return track.scan({instruction}).status;`, "llm:light")),
		automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatal(err)
	}
	rep, got := captureDryRun(t, b, watch, true)
	if rep.Status != automations.DryRunStopped || rep.Error != "this recipe calls the model before its primitive" || len(got) != 0 {
		t.Fatalf("report %s (%s), captured %+v", rep.Status, rep.Error, got)
	}
	if gen.CallCount() != 0 || scan.count() != 0 {
		t.Errorf("model calls %d, scan calls %d; want none", gen.CallCount(), scan.count())
	}
	// Without StopAtModelCalls the model call runs and the primitive is captured.
	rep, got = captureDryRun(t, b, watch, false)
	if rep.Status != db.RunSucceeded || len(got) != 1 || got[0] != (capturedPrompt{"track.scan", "done"}) || gen.CallCount() != 1 {
		t.Errorf("no stop: report %s (%s), captured %+v, model calls %d", rep.Status, rep.Error, got, gen.CallCount())
	}
}
