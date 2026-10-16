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
