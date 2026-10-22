package builtin

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/features"
)

var update = flag.Bool("update", false, "rewrite testdata/show_morning_brief.json")

func TestRegistry_ShippedRecipesParse(t *testing.T) {
	ids := map[string]bool{}
	for _, e := range All() {
		t.Run(e.ID, func(t *testing.T) {
			if ids[e.ID] || !automations.ValidSlug(e.ID) {
				t.Fatalf("id %q is duplicate or not slug-valid", e.ID)
			}
			ids[e.ID] = true
			r, err := ParseShipped(e)
			if err != nil {
				t.Fatalf("ParseShipped: %v", err)
			}
			if r.Name != e.Name || r.Scope.BuiltinID != e.ID {
				t.Errorf("name %q scope %+v, want %q in built-in %s", r.Name, r.Scope, e.Name, e.ID)
			}
			if r.Trigger.Kind != automations.TriggerSync || r.Trigger.Sync != string(e.Slot) {
				t.Errorf("trigger = %+v, want sync %s", r.Trigger, e.Slot)
			}
			var want []string
			for _, p := range e.Primitives {
				want = append(want, automations.CapabilityForPrimitive(p))
			}
			if got := slices.Sorted(slices.Values(r.Permissions)); !slices.Equal(got, slices.Sorted(slices.Values(want))) {
				t.Errorf("permissions = %v, want %v", got, want)
			}
			for _, p := range e.Prompts {
				if _, err := e.DefaultPrompt(p.Name, ""); err != nil {
					t.Errorf("DefaultPrompt(%q): %v", p.Name, err)
				}
			}
			if e.When == nil || e.When(testConfig(t)) == "" {
				t.Error("When is empty")
			}
		})
	}
}

// TestRegistry_PromptsCoverDefaultPromptCalls runs each shipped recipe and
// checks that builtin.defaultPrompt is asked for exactly the entry's prompt
// names (the shipped loop names them through a variable, so the script text
// alone cannot tell).
func TestRegistry_PromptsCoverDefaultPromptCalls(t *testing.T) {
	for _, e := range All() {
		t.Run(e.ID, func(t *testing.T) {
			f := newFixture(t)
			f.sync(t)
			run, err := f.runner.RunNow(context.Background(), e.ID, automations.BuiltinInput{})
			if err != nil || run.Status != db.RunSucceeded {
				t.Fatalf("RunNow = %+v, %v", run, err)
			}
			var want []string
			for _, p := range e.Prompts {
				want = append(want, p.Name)
			}
			if got := slices.Sorted(slices.Values(f.asked.all())); !slices.Equal(got, slices.Sorted(slices.Values(want))) {
				t.Errorf("defaultPrompt asked for %v, want %v", got, want)
			}
		})
	}
}

func TestRegistry_FeatureIDsHaveConfigKeys(t *testing.T) {
	for _, e := range All() {
		if len(e.FeatureIDs) == 0 {
			t.Errorf("%s: no feature ids", e.ID)
		}
		for _, id := range e.FeatureIDs {
			f, ok := features.ByID(id)
			if !ok || f.ConfigKey == "" || f.Enabled == nil {
				t.Errorf("%s: feature %q unknown or without a config key (%+v)", e.ID, id, f)
			}
		}
	}
}

func TestRegistry_RunNowNoteOnlyWhenNoRunNow(t *testing.T) {
	for _, e := range All() {
		if e.RunNow == (e.NoRunNowNote != "") {
			t.Errorf("%s: RunNow %v with note %q", e.ID, e.RunNow, e.NoRunNowNote)
		}
	}
	if e := mustEntry(t); !e.RunNow {
		t.Error("Morning brief offers no Run Now")
	}
}

func TestRegistry_ParametersHaveValues(t *testing.T) {
	cfg := testConfig(t)
	for _, e := range All() {
		for _, p := range e.Parameters {
			if p.Label == "" || paramValue(cfg, p.Key) == "" {
				t.Errorf("%s: parameter %s has no label or value", e.ID, p.Key)
			}
		}
	}
}

func TestRegistry_LookupAndAtSlot(t *testing.T) {
	if _, ok := Lookup("no-such"); ok {
		t.Error("Lookup found an unknown id")
	}
	got := AtSlot(SlotMorningBrief)
	if len(got) != 1 || got[0].ID != mbID {
		t.Errorf("AtSlot(morning_brief) = %v", got)
	}
	if want := filepath.Join("ws", "automations", ".builtin", "morning-brief.md"); OwnerCopyPath("ws", mbID) != want {
		t.Errorf("OwnerCopyPath = %q, want %q", OwnerCopyPath("ws", mbID), want)
	}
}

func TestRegistry_ShowJSONGolden(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	e := mustEntry(t)
	card, err := Card(f.d, f.cfg, e, f.row(t), f.clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	got, err := json.MarshalIndent(card, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	got = append(got, '\n')
	if !bytes.Contains(got, []byte(`"run_now": true`)) {
		t.Errorf("card has no \"run_now\": true:\n%s", got)
	}
	path := filepath.Join("testdata", "show_morning_brief.json")
	if *update {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with -update)", err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("card JSON differs from %s (run with -update):\n%s", path, got)
	}
}
