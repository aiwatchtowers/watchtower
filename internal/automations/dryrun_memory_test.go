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
