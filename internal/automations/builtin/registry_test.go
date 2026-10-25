package builtin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/features"
)

var update = flag.Bool("update", false, "rewrite the testdata/show_*.json goldens")

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

func TestBuiltinRecipes_HaveSummary(t *testing.T) {
	for _, e := range All() {
		r, err := ParseShipped(e)
		if err != nil {
			t.Fatalf("%s: %v", e.ID, err)
		}
		if n := len([]rune(r.Summary)); n == 0 || n > automations.MaxSummaryRunes {
			t.Errorf("%s: summary %q has %d runes", e.ID, r.Summary, n)
		}
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
			if run := f.runOnce(t, e.ID); run.Status != db.RunSucceeded {
				t.Fatalf("run = %+v", run)
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

// TestRunner_RunNowRefusedWithoutRunNow: a built-in that offers no Run Now
// (Reactions) is refused with its note, and nothing is queued.
func TestRunner_RunNowRefusedWithoutRunNow(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	e, ok := Lookup("reactions")
	if !ok || e.RunNow {
		t.Fatalf("reactions = %+v, %v; want an entry without Run Now", e, ok)
	}
	_, err := f.runner.RunNow(context.Background(), e.ID, automations.BuiltinInput{})
	if !errors.Is(err, ErrNoRunNow) || !strings.Contains(err.Error(), e.NoRunNowNote) {
		t.Fatalf("RunNow(reactions) = %v; want ErrNoRunNow naming %q", err, e.NoRunNowNote)
	}
	runs, err := f.d.ListAutomationRuns(f.rowOf(t, e.ID).ID, 0)
	if err != nil || len(runs) != 0 {
		t.Errorf("runs = %+v, %v; want none queued", runs, err)
	}
	if calls := f.c3["reaction.compose"].snapshot(); len(calls) != 0 {
		t.Errorf("reaction.compose ran %d times", len(calls))
	}
}

// TestCard_IntervalWithoutConfigIsTheDefault: with no config the interval
// shows the default hours, matching the When line.
func TestCard_IntervalWithoutConfigIsTheDefault(t *testing.T) {
	e, _ := Lookup("idea-finder")
	if got := paramValue(nil, "ideas.mine_interval_hours"); got != "6" || e.When(nil) != "Every 6 hours" {
		t.Errorf("value %q, When %q; want 6 and \"Every 6 hours\"", got, e.When(nil))
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
	for _, e := range All() {
		t.Run(e.ID, func(t *testing.T) {
			card, err := Card(f.d, f.cfg, f.ws, e, f.rowOf(t, e.ID), f.clock.Now())
			if err != nil {
				t.Fatal(err)
			}
			got, err := json.MarshalIndent(card, "", "  ")
			if err != nil {
				t.Fatal(err)
			}
			got = append(got, '\n')
			if want := fmt.Sprintf(`"run_now": %v`, e.RunNow); !bytes.Contains(got, []byte(want)) {
				t.Errorf("card has no %s:\n%s", want, got)
			}
			path := filepath.Join("testdata", "show_"+strings.ReplaceAll(e.ID, "-", "_")+".json")
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
		})
	}
}

// TestRenderOwnerCopy_ForEachC3Entry: each C3 built-in's owner copy with an
// edited prompt parses, and once confirmed its primitive gets exactly that
// text.
func TestRenderOwnerCopy_ForEachC3Entry(t *testing.T) {
	for id, prim := range map[string]string{
		"track-my-threads": "tracks.extract", "idea-finder": "ideas.consolidate", "reactions": "reaction.compose",
	} {
		t.Run(id, func(t *testing.T) {
			f := newFixture(t)
			e, ok := Lookup(id)
			if !ok || len(e.Prompts) != 1 {
				t.Fatalf("Lookup(%q) = %+v, %v; want one prompt", id, e, ok)
			}
			text := "My own " + e.Prompts[0].Name + " prompt: `%s` \u2028 \"quoted\"\n```\nend"
			data, err := RenderOwnerCopy(e, map[string]string{e.Prompts[0].Name: text})
			if err != nil {
				t.Fatalf("RenderOwnerCopy: %v", err)
			}
			f.writeCopyOf(t, id, data)
			f.sync(t)
			a := f.rowOf(t, id)
			if !a.Overridden || a.ParseError != "" {
				t.Fatalf("row = overridden %v parse %q", a.Overridden, a.ParseError)
			}
			if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.Now()); err != nil {
				t.Fatal(err)
			}
			if run := f.runOnce(t, id); run.Status != db.RunSucceeded {
				t.Fatalf("run = %+v", run)
			}
			calls := f.c3[prim].snapshot()
			if len(calls) != 1 || calls[0].Prompt != text {
				t.Fatalf("%s calls = %+v, want one with the copy's text", prim, calls)
			}
		})
	}
}

// TestCard_UnreadableCopyIsCopyError: an owner copy whose lstat fails with
// something other than not-exist (a permission error) is the card's
// copy_error, not a failed card.
func TestCard_UnreadableCopyIsCopyError(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	dir := filepath.Dir(OwnerCopyPath(f.ws, mbID))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	if _, err := os.Lstat(OwnerCopyPath(f.ws, mbID)); err == nil || os.IsNotExist(err) {
		t.Skipf("lstat in an unreadable directory gave %v (running as root?)", err)
	}
	card, err := Card(f.d, f.cfg, f.ws, mustEntry(t), f.row(t), f.clock.Now())
	if err != nil {
		t.Fatalf("Card: %v", err)
	}
	if !strings.Contains(card.CopyError, "reading the edited copy") {
		t.Errorf("copy_error = %q", card.CopyError)
	}
}

// TestCard_CostsCountTokensAndAStoppedBuiltinShowsOff: the primitives report
// tokens but no cost, so Costs carries the tokens with reported false; a
// built-in the daemon stopped (AUTO-08) shows off while its features are on.
func TestCard_CostsCountTokensAndAStoppedBuiltinShowsOff(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.brief.res.Usage = automations.PrimitiveUsage{InputTokens: 100, OutputTokens: 20}
	if o := f.slotOnce(t); o.Status != db.RunSucceeded {
		t.Fatalf("slot = %+v", o)
	}
	card, err := Card(f.d, f.cfg, f.ws, mustEntry(t), f.row(t), f.clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	if card.Costs.Tokens != 120 || card.Costs.Reported || !card.Enabled {
		t.Errorf("card costs = %+v enabled=%v; want 120 tokens, not reported, on", card.Costs, card.Enabled)
	}
	if err := f.d.DisableRunawayAutomation(f.row(t).ID, "runaway", f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if card, err = Card(f.d, f.cfg, f.ws, mustEntry(t), f.row(t), f.clock.Now()); err != nil || card.Enabled {
		t.Errorf("a stopped built-in's card: enabled=%v, %v; want off", card.Enabled, err)
	}
}

// TestCard_DoesAndResultFilter: every card lists what it does and names the
// Inbox filter its result lands in.
func TestCard_DoesAndResultFilter(t *testing.T) {
	want := map[string]string{"morning-brief": "day", "track-my-threads": "tracks", "idea-finder": "ideas", "reactions": "automations"}
	f := newFixture(t)
	for _, e := range All() {
		card, err := Card(f.d, f.cfg, f.ws, e, nil, f.clock.Now())
		if err != nil {
			t.Fatal(err)
		}
		if len(card.Does) < 1 {
			t.Errorf("%s: no Does steps", e.ID)
		}
		if card.ResultFilter != want[e.ID] {
			t.Errorf("%s: result_filter %q, want %q", e.ID, card.ResultFilter, want[e.ID])
		}
	}
}

// TestBuiltinRecipes_DescriptionIsOneSentence: the built-in card's lede shows
// the whole description, so it stays a single sentence; detail goes in Does.
func TestBuiltinRecipes_DescriptionIsOneSentence(t *testing.T) {
	for _, e := range All() {
		r, err := ParseShipped(e)
		if err != nil {
			t.Fatalf("%s: %v", e.ID, err)
		}
		d := strings.TrimSpace(r.Description)
		if d == "" || strings.ContainsAny(d, "\n") {
			t.Errorf("%s: description %q is empty or spans lines", e.ID, d)
		}
		for _, sep := range []string{". ", "! ", "? "} {
			if strings.Contains(d, sep) {
				t.Errorf("%s: description %q has more than one sentence", e.ID, d)
			}
		}
	}
}
