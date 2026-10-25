package automations

import (
	"context"
	"errors"
	"testing"

	"watchtower/internal/db"
)

// The script cannot reach an undeclared primitive (its namespace is not
// installed); the call's own gate still denies it.
func TestBuiltinSDK_PermissionDeniedWithoutCapability(t *testing.T) {
	scope := Scope{Kind: ScopePersonal, BuiltinID: "morning-brief"}
	m, err := ParseManifest([]string{"builtin:brief.compose"}, nil, scope)
	if err != nil {
		t.Fatal(err)
	}
	called := 0
	b := Backends{Primitives: map[string]PrimitiveFunc{"plan.compose": func(context.Context, PrimitiveCall) (PrimitiveResult, error) {
		called++
		return PrimitiveResult{Status: "done"}, nil
	}}}
	clock := RealClock{}
	env := &Env{
		Ctx: context.Background(), Run: &db.AutomationRun{ID: 1, Trigger: db.TriggerSync},
		Automation: &db.Automation{ID: 1, Origin: db.OriginBuiltin, BuiltinID: "morning-brief"},
		Recipe:     &Recipe{Scope: scope}, Manifest: m, Journal: NewMemoryJournal(),
		Meter: NewMeter(Budget{Tokens: 50000, Minutes: 5}, clock),
	}
	_, err = newBuiltinSDK(b).call(env, "plan.compose", map[string]any{"prompt": "P"}, nil)
	var pd *PermissionDenied
	if !errors.As(err, &pd) || pd.Needed != "builtin:plan.compose" {
		t.Fatalf("err = %v; want PermissionDenied needing builtin:plan.compose", err)
	}
	if called != 0 {
		t.Errorf("primitive called %d times", called)
	}
	steps := env.Journal.Steps()
	if len(steps) != 1 || steps[0].Status != StepDenied || steps[0].Name != "plan.compose" {
		t.Errorf("steps = %+v", steps)
	}
}
