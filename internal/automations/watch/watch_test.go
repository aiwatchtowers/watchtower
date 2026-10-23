package watch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

var testNow = time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)

func personal() automations.Scope { return automations.Scope{Kind: automations.ScopePersonal} }

func TestWatchRender_ParsesAndRoundTripsInstruction(t *testing.T) {
	instr := "Watch for \"refund\" or `ACME-1` mentions, 100%s done, then stop"
	data, err := Render("Refund \"watch\"", instr)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	r, err := automations.ParseRecipe(TemplateName, data, personal())
	if err != nil {
		t.Fatalf("ParseRecipe: %v\n%s", err, data)
	}
	if r.Name != "Refund \"watch\"" {
		t.Errorf("name = %q", r.Name)
	}
	if r.Trigger.Sync != "custom_tracks" {
		t.Errorf("trigger = %+v; want sync custom_tracks", r.Trigger)
	}
	if len(r.Permissions) != 1 || r.Permissions[0] != "track:scan" || len(r.Outputs) != 0 {
		t.Errorf("permissions %v outputs %v; want [track:scan] and none", r.Permissions, r.Outputs)
	}
	if r.Budget.Tokens != 200000 || r.Budget.Minutes != 10 {
		t.Errorf("budget = %+v; want 200000 tokens / 10 minutes", r.Budget)
	}
	if !strings.Contains(r.Script, "track.scan({ instruction });") {
		t.Errorf("script lacks the scan call:\n%s", r.Script)
	}
	if strings.Contains(string(data), " ") {
		t.Error("the raw U+2028 reached the recipe; want it escaped")
	}
	got, ok := Instruction(data)
	if !ok || got != instr {
		t.Fatalf("Instruction = %q, %v; want %q", got, ok, instr)
	}

	edited, err := SetInstruction(data, "new words")
	if err != nil {
		t.Fatalf("SetInstruction: %v", err)
	}
	if got, ok := Instruction(edited); !ok || got != "new words" {
		t.Fatalf("Instruction after Set = %q, %v", got, ok)
	}
	if _, err := automations.ParseRecipe(TemplateName, edited, personal()); err != nil {
		t.Fatalf("edited recipe does not parse: %v", err)
	}
	if strings.Replace(string(edited), `"new words"`, "", 1) != strings.Replace(string(data), jsonString(instr), "", 1) {
		t.Error("SetInstruction changed more than the instruction literal")
	}
}

func TestWatchSetInstruction_RefusesEditedRecipe(t *testing.T) {
	data, err := Render("Refund", "watch the refund")
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	line := `const instruction = "watch the refund";`
	cases := map[string]string{
		"line removed":     strings.Replace(string(data), line, `const words = "watch the refund";`, 1),
		"line duplicated":  strings.Replace(string(data), line, line+"\n"+line, 1),
		"not a literal":    strings.Replace(string(data), line, `const instruction = "a" + "b";`, 1),
		"indented literal": strings.Replace(string(data), line, "  "+line, 1),
	}
	for name, recipe := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := SetInstruction([]byte(recipe), "x"); !errors.Is(err, ErrNotTemplateShaped) {
				t.Fatalf("SetInstruction err = %v; want ErrNotTemplateShaped", err)
			}
			if _, ok := Instruction([]byte(recipe)); ok {
				t.Fatal("Instruction read a recipe that is not template-shaped")
			}
		})
	}
}

type startFixture struct {
	d  *db.DB
	ix *automations.Indexer
	ws string
}

func newStartFixture(t *testing.T) startFixture {
	t.Helper()
	ws := t.TempDir()
	d, err := db.Open(filepath.Join(ws, "watchtower.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return startFixture{d: d, ix: automations.NewIndexer(d, ws, automationstest.NewFakeClock(testNow)), ws: ws}
}

func (f startFixture) track(t *testing.T, tr db.Track) db.Track {
	t.Helper()
	if tr.AssigneeUserID == "" {
		tr.AssigneeUserID = "U1"
	}
	id, err := f.d.CreateCustomTrack(tr)
	if err != nil {
		t.Fatalf("create custom track: %v", err)
	}
	got, err := f.d.GetTrackByID(int(id))
	if err != nil {
		t.Fatalf("load track: %v", err)
	}
	return *got
}

func TestWatchStart_BindsConfirmsAndIsIdempotent(t *testing.T) {
	f := newStartFixture(t)
	tr := f.track(t, db.Track{Text: "Refund for ACME!", Context: "the context", Instruction: "watch the refund"})
	ctx := context.Background()

	a, err := Start(ctx, f.d, f.ix, f.ws, tr, StartOptions{Confirm: true, Now: testNow})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if base := filepath.Base(a.Path); base != "watch-"+strconv.Itoa(tr.ID)+"-refund-for-acme.md" {
		t.Errorf("path = %s", a.Path)
	}
	if a.ConfirmedHash == "" || a.ConfirmedHash != a.ApprovalHash {
		t.Errorf("confirmed %q approval %q; want confirmed", a.ConfirmedHash, a.ApprovalHash)
	}
	if !a.Enabled {
		t.Error("recipe not enabled for an enabled track")
	}
	data, err := os.ReadFile(a.Path)
	if err != nil {
		t.Fatalf("read recipe: %v", err)
	}
	if got, ok := Instruction(data); !ok || got != "watch the refund" {
		t.Errorf("recipe instruction = %q, %v", got, ok)
	}
	bound, err := f.d.GetWatchTrack(a.ID)
	if err != nil || bound == nil || bound.ID != tr.ID || !bound.Enabled {
		t.Fatalf("GetWatchTrack = %+v, %v; want track %d bound and enabled", bound, err, tr.ID)
	}

	// Idempotent: a second Start (even with the stale, unbound t) writes nothing.
	if err := os.WriteFile(a.Path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(a.Path)
	again, err := Start(ctx, f.d, f.ix, f.ws, tr, StartOptions{Confirm: true, Now: testNow.Add(time.Hour)})
	if err != nil {
		t.Fatalf("second Start: %v", err)
	}
	if again.ID != a.ID || !again.UpdatedAt.Equal(a.UpdatedAt) {
		t.Errorf("second Start = id %d updated %v; want %d unchanged %v", again.ID, again.UpdatedAt, a.ID, a.UpdatedAt)
	}
	after, _ := os.Stat(a.Path)
	if !after.ModTime().Equal(before.ModTime()) {
		t.Error("second Start rewrote the recipe file")
	}
	entries, _ := os.ReadDir(automations.PersonalDir(f.ws))
	if len(entries) != 1 {
		t.Errorf("personal folder holds %d files; want 1", len(entries))
	}
}

func TestWatchStart_UnconfirmedWithoutConfirm(t *testing.T) {
	f := newStartFixture(t)
	tr := f.track(t, db.Track{Text: "Release train", Context: "context words"})
	if err := f.d.SetTrackEnabled(tr.ID, false); err != nil {
		t.Fatalf("disable track: %v", err)
	}
	tr.Enabled = false

	a, err := Start(context.Background(), f.d, f.ix, f.ws, tr, StartOptions{Now: testNow})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if a.ConfirmedHash != "" {
		t.Errorf("confirmed_hash = %q; want unconfirmed", a.ConfirmedHash)
	}
	if a.Enabled {
		t.Error("recipe enabled for a paused track")
	}
	data, err := os.ReadFile(a.Path)
	if err != nil {
		t.Fatalf("read recipe: %v", err)
	}
	// No instruction on the row: the context stands in.
	if got, _ := Instruction(data); got != "context words" {
		t.Errorf("instruction = %q; want the track's context", got)
	}
	bound, err := f.d.GetWatchTrack(a.ID)
	if err != nil || bound == nil || bound.Enabled {
		t.Fatalf("GetWatchTrack = %+v, %v; want bound and paused", bound, err)
	}
}

func TestWatchStart_SameTitleTwoTracksTwoFiles(t *testing.T) {
	f := newStartFixture(t)
	ctx := context.Background()
	one := f.track(t, db.Track{Text: "Same title"})
	two := f.track(t, db.Track{Text: "Same title"})

	a1, err := Start(ctx, f.d, f.ix, f.ws, one, StartOptions{Confirm: true, Now: testNow})
	if err != nil {
		t.Fatalf("Start one: %v", err)
	}
	a2, err := Start(ctx, f.d, f.ix, f.ws, two, StartOptions{Confirm: true, Now: testNow})
	if err != nil {
		t.Fatalf("Start two: %v", err)
	}
	if a1.ID == a2.ID || a1.Path == a2.Path {
		t.Fatalf("two tracks share automation %d / %s", a1.ID, a1.Path)
	}
	data, err := os.ReadFile(a2.Path)
	if err != nil {
		t.Fatal(err)
	}
	// No instruction and no context: the text stands in.
	if got, _ := Instruction(data); got != "Same title" {
		t.Errorf("instruction = %q; want the track's text", got)
	}
	for _, p := range []struct {
		tr db.Track
		a  *db.Automation
	}{{one, a1}, {two, a2}} {
		bound, err := f.d.GetWatchTrack(p.a.ID)
		if err != nil || bound == nil || bound.ID != p.tr.ID {
			t.Errorf("automation %d bound to %+v, %v; want track %d", p.a.ID, bound, err, p.tr.ID)
		}
	}
}
