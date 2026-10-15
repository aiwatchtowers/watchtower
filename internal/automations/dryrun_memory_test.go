package automations_test

import (
	"context"
	"path/filepath"
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
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
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
