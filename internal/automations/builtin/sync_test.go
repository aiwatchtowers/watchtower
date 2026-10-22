package builtin

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// slotOnce runs the Morning brief slot and returns its one outcome.
func (f *fixture) slotOnce(t *testing.T) SlotOutcome {
	t.Helper()
	out := f.runner.RunSlot(context.Background(), SlotMorningBrief)
	if len(out) != 1 {
		t.Fatalf("RunSlot = %+v, want one outcome", out)
	}
	return out[0]
}

func TestAuto06_ShippedBuiltinRunsWithoutOwnerConfirmation(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	rep := f.sync(t)
	a := f.row(t)
	r, err := ParseShipped(e)
	if err != nil {
		t.Fatal(err)
	}
	if !a.IsBuiltin() || a.Path != "builtin:"+mbID || a.Overridden || a.BuiltinBaseHash != "" {
		t.Errorf("row = origin %q path %q overridden %v base %q", a.Origin, a.Path, a.Overridden, a.BuiltinBaseHash)
	}
	if a.RecipeText != string(e.Recipe) || a.ContentHash != e.ShippedContentHash() {
		t.Error("the row does not hold the shipped text")
	}
	if !a.Confirmed() || a.ConfirmedHash != automations.ApprovalHash(r) {
		t.Errorf("confirmed %v at %q, want the shipped approval hash", a.Confirmed(), a.ConfirmedHash)
	}
	if !slices.Equal(rep.Confirmed, []string{mbID}) || !slices.Equal(rep.Indexed, []string{mbID}) || len(rep.Errors) != 0 {
		t.Errorf("report = %+v", rep)
	}
	if o := f.slotOnce(t); o.Status != db.RunSucceeded {
		t.Errorf("slot = %+v, want a succeeded run", o)
	}
}

func TestAuto06_OwnerCopyNeedsConfirmation(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	f.sync(t)
	f.writeCopy(t, editedCopy(t, e, "My own brief prompt for %s on %s."))
	rep := f.sync(t)
	a := f.row(t)
	if !a.Overridden || a.BuiltinBaseHash != e.ShippedContentHash() || a.ParseError != "" {
		t.Errorf("row = overridden %v base %q parse %q", a.Overridden, a.BuiltinBaseHash, a.ParseError)
	}
	if a.Confirmed() {
		t.Fatal("the owner's copy runs without the owner's confirmation")
	}
	if !slices.Equal(rep.Overridden, []string{mbID}) || len(rep.Confirmed) != 0 {
		t.Errorf("report = %+v", rep)
	}
	if o := f.slotOnce(t); o.Skipped != SkippedNotConfirmed || len(f.runs(t)) != 0 {
		t.Errorf("slot = %+v with %d runs, want not_confirmed and no run", o, len(f.runs(t)))
	}
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if o := f.slotOnce(t); o.Status != db.RunSucceeded {
		t.Errorf("slot after the owner's confirmation = %+v", o)
	}
}

func TestAuto06_HandEditedCopyStopsTheBuiltIn(t *testing.T) {
	cases := map[string]func(copyText []byte) []byte{
		"prompt edited": func(c []byte) []byte {
			return bytes.Replace(c, []byte("Confirmed prompt"), []byte("Hand-edited prompt"), 1)
		},
		"permission added": func(c []byte) []byte {
			return bytes.Replace(c, []byte("permissions:\n"), []byte("permissions:\n  - llm:light\n"), 1)
		},
		"parse error": func(c []byte) []byte {
			return bytes.Replace(c, []byte("trigger:"), []byte("trigger: {nope: 1}\nx:"), 1)
		},
	}
	for name, edit := range cases {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			e := mustEntry(t)
			confirmed := editedCopy(t, e, "Confirmed prompt for %s on %s.")
			f.writeCopy(t, confirmed)
			f.sync(t)
			a := f.row(t)
			if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.Now()); err != nil {
				t.Fatal(err)
			}
			edited := edit(confirmed)
			if bytes.Equal(edited, confirmed) {
				t.Fatal("the edit changed nothing")
			}
			f.writeCopy(t, edited)
			f.sync(t)
			a = f.row(t)
			if a.Confirmed() || a.RecipeText != string(edited) {
				t.Fatalf("after a hand edit: confirmed %v, text edited %v", a.Confirmed(), a.RecipeText == string(edited))
			}
			if o := f.slotOnce(t); o.Skipped != SkippedNotConfirmed {
				t.Errorf("slot = %+v, want not_confirmed", o)
			}
			if n := len(f.runs(t)); n != 0 || len(f.brief.snapshot()) != 0 || f.gate.count() != 0 {
				t.Errorf("%d runs, %d brief calls, %d gate calls; want none", n, len(f.brief.snapshot()), f.gate.count())
			}
			if _, err := f.runner.RunNow(context.Background(), mbID, automations.BuiltinInput{}); !isNotRunnable(err) {
				t.Errorf("RunNow = %v, want ErrNotRunnable", err)
			}
		})
	}
}

func TestAuto06_CopyEqualToShippedRuns(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	f.writeCopy(t, e.Recipe)
	f.sync(t)
	a := f.row(t)
	if !a.Overridden || !a.Confirmed() {
		t.Fatalf("a copy equal to the shipped text: overridden %v confirmed %v", a.Overridden, a.Confirmed())
	}
	if o := f.slotOnce(t); o.Status != db.RunSucceeded {
		t.Errorf("slot = %+v", o)
	}
}

func TestBuiltinSync_CopySymlinkIsNeverRead(t *testing.T) {
	e := mustEntry(t)
	cases := map[string]func(t *testing.T, path string, target string){
		"symlink": func(t *testing.T, path, target string) {
			if err := os.Symlink(target, path); err != nil {
				t.Fatal(err)
			}
		},
		"directory": func(t *testing.T, path, _ string) {
			if err := os.Mkdir(path, 0o700); err != nil {
				t.Fatal(err)
			}
		},
		"fifo": func(t *testing.T, path, _ string) {
			if err := syscall.Mkfifo(path, 0o600); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, mk := range cases {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			target := filepath.Join(t.TempDir(), "elsewhere.md")
			if err := os.WriteFile(target, editedCopy(t, e, "Linked prompt for %s on %s."), 0o600); err != nil {
				t.Fatal(err)
			}
			path := OwnerCopyPath(f.ws, mbID)
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			mk(t, path, target)
			rep := f.sync(t)
			a := f.row(t)
			if a.Overridden || a.RecipeText != string(e.Recipe) || !a.Confirmed() {
				t.Errorf("row = overridden %v shipped %v confirmed %v; want the shipped text", a.Overridden,
					a.RecipeText == string(e.Recipe), a.Confirmed())
			}
			if rep.Errors[mbID] != copyNotRegularNote {
				t.Errorf("report errors = %v", rep.Errors)
			}
		})
	}
}

func TestBuiltinSync_ShippedUpdateMovesSilently(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	old := bytes.Replace(e.Recipe, []byte("minutes: 15"), []byte("minutes: 10"), 1)
	withShipped(t, old)
	f.sync(t)
	if a := f.row(t); a.RecipeText != string(old) || !a.Confirmed() {
		t.Fatal("the old release's text is not indexed and confirmed")
	}
	withShipped(t, e.Recipe) // the new release
	rep := f.sync(t)
	a := f.row(t)
	r, err := ParseShipped(e)
	if err != nil {
		t.Fatal(err)
	}
	if a.RecipeText != string(e.Recipe) || a.Overridden || !a.Confirmed() || a.ConfirmedHash != automations.ApprovalHash(r) {
		t.Errorf("after the update: new text %v overridden %v confirmed %v", a.RecipeText == string(e.Recipe), a.Overridden, a.Confirmed())
	}
	if !slices.Equal(rep.Confirmed, []string{mbID}) {
		t.Errorf("report = %+v", rep)
	}
}

func TestBuiltinSync_OverriddenKeepsCopyAndFlagsUpdate(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	oldRelease := e
	oldRelease.Recipe = bytes.Replace(e.Recipe, []byte("minutes: 15"), []byte("minutes: 10"), 1)
	withShipped(t, oldRelease.Recipe)
	f.sync(t)
	copyText := editedCopy(t, oldRelease, "Owner prompt for %s on %s.")
	f.writeCopy(t, copyText)
	f.sync(t)
	card, err := Card(f.d, f.cfg, oldRelease, f.row(t), f.clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	if card.UpdateAvailable || card.BaseHash != oldRelease.ShippedContentHash() {
		t.Errorf("before the update: update %v base %q", card.UpdateAvailable, card.BaseHash)
	}

	withShipped(t, e.Recipe) // the new release
	f.sync(t)
	a := f.row(t)
	if a.RecipeText != string(copyText) || !a.Overridden || a.BuiltinBaseHash != oldRelease.ShippedContentHash() {
		t.Errorf("after the update: copy kept %v overridden %v base %q", a.RecipeText == string(copyText), a.Overridden, a.BuiltinBaseHash)
	}
	card, err = Card(f.d, f.cfg, e, a, f.clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !card.UpdateAvailable || card.ShippedHash != e.ShippedContentHash() {
		t.Errorf("card = update %v shipped %q", card.UpdateAvailable, card.ShippedHash)
	}
}

func TestBuiltinSync_ResetReturnsToShipped(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	f.writeCopy(t, editedCopy(t, e, "Owner prompt for %s on %s."))
	f.sync(t)
	if a := f.row(t); !a.Overridden || a.Confirmed() {
		t.Fatal("the copy is not indexed unconfirmed")
	}
	if err := os.Remove(OwnerCopyPath(f.ws, mbID)); err != nil {
		t.Fatal(err)
	}
	a, err := SyncOne(context.Background(), f.d, f.ws, f.cfg, mbID, f.clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	if a.Overridden || a.BuiltinBaseHash != "" || a.RecipeText != string(e.Recipe) || !a.Confirmed() {
		t.Errorf("after reset: overridden %v base %q shipped %v confirmed %v", a.Overridden, a.BuiltinBaseHash,
			a.RecipeText == string(e.Recipe), a.Confirmed())
	}
}

func TestBuiltinSync_PersonalSlugTwinIsSeparate(t *testing.T) {
	const twin = "---\nname: My morning\ntrigger:\n  manual: true\n---\nA personal recipe.\n\n```js\nlog(\"hi\");\n```\n"
	for _, order := range []string{"built-in first", "personal first"} {
		t.Run(order, func(t *testing.T) {
			f := newFixture(t)
			e := mustEntry(t)
			ix := automations.NewIndexer(f.d, f.ws, f.clock)
			dir := automations.PersonalDir(f.ws)
			if err := os.MkdirAll(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, mbID+".md"), []byte(twin), 0o600); err != nil {
				t.Fatal(err)
			}
			f.writeCopy(t, e.Recipe) // .builtin/ lives inside the Personal folder
			rescan := func() automations.RescanReport {
				rep, err := ix.RescanPersonal(context.Background())
				if err != nil {
					t.Fatal(err)
				}
				return rep
			}
			if order == "built-in first" {
				f.sync(t)
				if rep := rescan(); len(rep.Skipped) != 0 || rep.Removed != 0 {
					t.Errorf("rescan = %+v; the twin must not be skipped, nothing removed", rep)
				}
			} else {
				rescan()
				f.sync(t)
			}
			// Again in the other order: neither touches the other's row.
			rescan()
			f.sync(t)

			owner, err := f.d.GetAutomationBySlug("personal", 0, mbID)
			if err != nil {
				t.Fatalf("the personal twin has no row of its own: %v", err)
			}
			b := f.row(t)
			if owner.ID == b.ID || owner.IsBuiltin() || owner.RemovedAt != nil || owner.RecipeText != twin {
				t.Errorf("twin row = %+v", owner)
			}
			if b.RemovedAt != nil || b.RecipeText != string(e.Recipe) || !b.Confirmed() {
				t.Errorf("built-in row removed %v shipped %v confirmed %v", b.RemovedAt != nil, b.RecipeText == string(e.Recipe), b.Confirmed())
			}
			rows, err := f.d.ListAutomations(db.AutomationFilter{Scope: "personal", IncludeRemoved: true})
			if err != nil {
				t.Fatal(err)
			}
			if len(rows) != 2 {
				t.Errorf("%d personal rows, want the twin and the built-in", len(rows))
			}
		})
	}
}

func TestBuiltinSync_PersonalRecipeDeclaringSyncIsAParseError(t *testing.T) {
	f := newFixture(t)
	e := mustEntry(t)
	f.sync(t)
	dir := automations.PersonalDir(f.ws)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, mbID+".md"), e.Recipe, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := automations.NewIndexer(f.d, f.ws, f.clock).RescanPersonal(context.Background()); err != nil {
		t.Fatal(err)
	}
	owner, err := f.d.GetAutomationBySlug("personal", 0, mbID)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(owner.ParseError, "built-in automation") || owner.Runnable() {
		t.Errorf("copied built-in in the Personal folder: parse error %q runnable %v", owner.ParseError, owner.Runnable())
	}
	if b := f.row(t); b.ID == owner.ID || !b.Confirmed() {
		t.Error("the built-in row was shared or unconfirmed")
	}
}

func TestBuiltinSync_UnchangedWritesNothing(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	before := f.row(t)
	gen, err := f.d.AutomationScopeGeneration("personal", 0)
	if err != nil {
		t.Fatal(err)
	}
	f.clock.Advance(time.Hour)
	rep := f.sync(t)
	after := f.row(t)
	gen2, err := f.d.AutomationScopeGeneration("personal", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Indexed)+len(rep.Confirmed) != 0 || !after.UpdatedAt.Equal(before.UpdatedAt) || gen != gen2 {
		t.Errorf("an unchanged sync wrote: report %+v, updated_at %v → %v", rep, before.UpdatedAt, after.UpdatedAt)
	}
}

func TestBuiltinSync_EnabledMirrorsConfig(t *testing.T) {
	f := newFixture(t)
	cases := []struct {
		brief, plan, want bool
	}{{false, false, false}, {true, false, true}, {false, true, true}, {false, false, false}, {true, true, true}}
	for _, c := range cases {
		f.cfg.Briefing.Enabled, f.cfg.DayPlan.Enabled = c.brief, c.plan
		f.sync(t)
		if got := f.row(t).Enabled; got != c.want {
			t.Errorf("briefing %v day plan %v: enabled %v, want %v", c.brief, c.plan, got, c.want)
		}
	}
}

func TestSyncOne_UnknownID(t *testing.T) {
	f := newFixture(t)
	if _, err := SyncOne(context.Background(), f.d, f.ws, f.cfg, "no-such", f.clock.Now()); err == nil {
		t.Error("SyncOne of an unknown id succeeded")
	}
}
