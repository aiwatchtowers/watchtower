package automations

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/db"
)

// indexerClock is a settable Clock for indexer tests.
type indexerClock struct{ now time.Time }

func (c *indexerClock) Now() time.Time                       { return c.now }
func (c *indexerClock) After(time.Duration) <-chan time.Time { return make(chan time.Time) }

const indexerRecipe = `---
name: Morning mail
trigger:
  schedule: "0 9 * * *"
permissions:
  - llm:light
outputs: [inbox]
---
DESCRIPTION

` + "```js\nSCRIPT\n```\n"

func recipeText(description, script string) string {
	r := strings.Replace(indexerRecipe, "DESCRIPTION", description, 1)
	return strings.Replace(r, "SCRIPT", script, 1)
}

type indexerFixture struct {
	d     *db.DB
	ix    *Indexer
	clock *indexerClock
	ws    string // workspace dir
	dir   string // canonical personal folder
}

func newIndexerFixture(t *testing.T) *indexerFixture {
	t.Helper()
	ws := t.TempDir()
	clock := &indexerClock{now: time.Date(2026, 10, 14, 10, 0, 0, 0, time.UTC)}
	d := openManifestTestDB(t)
	dir, err := canonicalDir(PersonalDir(ws))
	if err != nil {
		t.Fatal(err)
	}
	return &indexerFixture{d: d, ix: NewIndexer(d, ws, clock), clock: clock, ws: ws, dir: dir}
}

func (f *indexerFixture) write(t *testing.T, name, content string) string {
	t.Helper()
	if err := os.MkdirAll(f.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(f.dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func (f *indexerFixture) rescan(t *testing.T) RescanReport {
	t.Helper()
	rep, err := f.ix.RescanPersonal(context.Background())
	if err != nil {
		t.Fatalf("RescanPersonal: %v", err)
	}
	return rep
}

func (f *indexerFixture) row(t *testing.T, slug string) *db.Automation {
	t.Helper()
	a, err := f.d.GetAutomationBySlug("personal", 0, slug)
	if err != nil {
		t.Fatalf("GetAutomationBySlug(%s): %v", slug, err)
	}
	return a
}

// confirmEnable confirms the row's current hash and enables it.
func (f *indexerFixture) confirmEnable(t *testing.T, slug string) {
	t.Helper()
	a := f.row(t, slug)
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.now); err != nil {
		t.Fatal(err)
	}
	if err := f.d.SetAutomationEnabled(a.ID, true, f.clock.now); err != nil {
		t.Fatal(err)
	}
}

func wantCounts(t *testing.T, rep RescanReport, indexed, unchanged, removed int) {
	t.Helper()
	if rep.Indexed != indexed || rep.Unchanged != unchanged || rep.Removed != removed {
		t.Errorf("report indexed/unchanged/removed = %d/%d/%d, want %d/%d/%d (%+v)",
			rep.Indexed, rep.Unchanged, rep.Removed, indexed, unchanged, removed, rep)
	}
}

func TestRescan_MissingDirIsEmpty(t *testing.T) {
	f := newIndexerFixture(t)
	rep := f.rescan(t)
	wantCounts(t, rep, 0, 0, 0)
	if len(rep.Skipped) != 0 || len(rep.NeedConfirmation) != 0 {
		t.Errorf("report = %+v, want empty", rep)
	}
}

func TestRescan_IndexesNewRecipeUnconfirmedAndDisabled(t *testing.T) {
	f := newIndexerFixture(t)
	path := f.write(t, "mail.md", recipeText("Sums up mail.", `log("hi")`))
	rep := f.rescan(t)
	wantCounts(t, rep, 1, 0, 0)
	a := f.row(t, "mail")
	if a.Runnable() || a.Enabled || a.ConfirmedHash != "" {
		t.Errorf("new row runnable=%v enabled=%v confirmed=%q, want none", a.Runnable(), a.Enabled, a.ConfirmedHash)
	}
	if len(rep.NeedConfirmation) != 1 || rep.NeedConfirmation[0] != a.ID {
		t.Errorf("NeedConfirmation = %v, want [%d]", rep.NeedConfirmation, a.ID)
	}
	checks := map[string][2]string{
		"path":         {a.Path, path},
		"name":         {a.Name, "Morning mail"},
		"trigger_kind": {a.TriggerKind, "schedule"},
		"trigger_spec": {a.TriggerSpec, `{"schedule":"0 9 * * *"}`},
		"permissions":  {a.PermissionsJSON, `["llm:light"]`},
		"outputs":      {a.OutputsJSON, `["inbox"]`},
		"parse_error":  {a.ParseError, ""},
		"recipe_text":  {a.RecipeText, recipeText("Sums up mail.", `log("hi")`)},
	}
	for col, got := range checks {
		if got[0] != got[1] {
			t.Errorf("%s = %q, want %q", col, got[0], got[1])
		}
	}
	if a.ApprovalHash == "" || a.ContentHash != ContentHash([]byte(a.RecipeText)) {
		t.Errorf("hashes approval=%q content=%q", a.ApprovalHash, a.ContentHash)
	}
}

func TestRescan_UnchangedContentIsNoop(t *testing.T) {
	f := newIndexerFixture(t)
	f.write(t, "mail.md", recipeText("d", `log("hi")`))
	f.rescan(t)
	a := f.row(t, "mail")
	mustExec(t, f.d, `UPDATE automations SET updated_at = '2020-01-01T00:00:00Z' WHERE id = ?`, a.ID)
	rep := f.rescan(t)
	wantCounts(t, rep, 0, 1, 0)
	if got := f.row(t, "mail").UpdatedAt.Format(time.RFC3339); got != "2020-01-01T00:00:00Z" {
		t.Errorf("updated_at = %s, want untouched", got)
	}
	if len(rep.NeedConfirmation) != 1 {
		t.Errorf("NeedConfirmation = %v, want the still unconfirmed row", rep.NeedConfirmation)
	}
}

func TestRescan_ChangedOutsideWatchtowerNeedsConfirmation(t *testing.T) {
	f := newIndexerFixture(t)
	f.write(t, "mail.md", recipeText("d", `log("hi")`))
	f.rescan(t)
	f.confirmEnable(t, "mail")
	before := f.row(t, "mail")
	if !before.Runnable() {
		t.Fatal("confirmed row not runnable")
	}

	f.write(t, "mail.md", recipeText("a longer description", `log("hi")`))
	rep := f.rescan(t)
	wantCounts(t, rep, 1, 0, 0)
	if a := f.row(t, "mail"); !a.Runnable() || a.ApprovalHash != before.ApprovalHash {
		t.Errorf("description-only edit: runnable=%v, approval changed=%v; want runnable, same hash",
			a.Runnable(), a.ApprovalHash != before.ApprovalHash)
	}
	if len(rep.NeedConfirmation) != 0 {
		t.Errorf("NeedConfirmation = %v after a description edit, want none", rep.NeedConfirmation)
	}

	f.write(t, "mail.md", recipeText("a longer description", `log("changed")`))
	rep = f.rescan(t)
	a := f.row(t, "mail")
	if a.Runnable() || a.ApprovalHash == before.ApprovalHash || a.ConfirmedHash != before.ConfirmedHash || !a.Enabled {
		t.Errorf("script edit: runnable=%v approval=%q confirmed=%q enabled=%v; want not runnable, new hash, old confirmation kept",
			a.Runnable(), a.ApprovalHash, a.ConfirmedHash, a.Enabled)
	}
	if len(rep.NeedConfirmation) != 1 || rep.NeedConfirmation[0] != a.ID {
		t.Errorf("NeedConfirmation = %v, want [%d]", rep.NeedConfirmation, a.ID)
	}
}

func TestRescan_ParseErrorIndexedNotRunnable(t *testing.T) {
	f := newIndexerFixture(t)
	f.write(t, "broken.md", "---\nname: x\n---\nno script here\n")
	rep := f.rescan(t)
	wantCounts(t, rep, 1, 0, 0)
	a := f.row(t, "broken")
	if a.ParseError == "" || a.Runnable() || a.TriggerKind != "" {
		t.Errorf("parse_error=%q runnable=%v trigger=%q; want an error, not runnable, no trigger", a.ParseError, a.Runnable(), a.TriggerKind)
	}
	if len(rep.NeedConfirmation) != 0 {
		t.Errorf("NeedConfirmation = %v, want none for an unparsable recipe", rep.NeedConfirmation)
	}
	if rep := f.rescan(t); rep.Unchanged != 1 {
		t.Errorf("second rescan of the same broken file: %+v, want Unchanged=1", rep)
	}
}

func TestRescan_OversizedFileIsParseError(t *testing.T) {
	f := newIndexerFixture(t)
	f.write(t, "big.md", strings.Repeat("x", MaxRecipeBytes+10))
	f.rescan(t)
	if a := f.row(t, "big"); a.ParseError == "" || len(a.RecipeText) > MaxRecipeBytes+1 {
		t.Errorf("parse_error=%q recipe_text len %d; want an error and at most %d bytes kept", a.ParseError, len(a.RecipeText), MaxRecipeBytes+1)
	}
}

func TestRescan_BadSlugAndOtherExtensionsSkipped(t *testing.T) {
	f := newIndexerFixture(t)
	f.write(t, "Bad_Name.md", recipeText("d", "1"))
	f.write(t, "notes.txt", "hello")
	f.write(t, "mail.md.swp", "junk")
	if err := os.MkdirAll(filepath.Join(f.dir, "sub.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.write(t, "ok.md", recipeText("d", "1"))
	rep := f.rescan(t)
	wantCounts(t, rep, 1, 0, 0)
	if len(rep.Skipped) != 1 || rep.Skipped[0].Path != filepath.Join(f.dir, "Bad_Name.md") ||
		!strings.Contains(rep.Skipped[0].Reason, "not a valid automation slug") {
		t.Errorf("Skipped = %+v, want only Bad_Name.md with a slug reason", rep.Skipped)
	}
	all, err := f.d.ListAutomations(db.AutomationFilter{IncludeRemoved: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].Slug != "ok" {
		t.Errorf("rows = %+v, want only ok", all)
	}
}

func TestRescan_RemovedFileMarked(t *testing.T) {
	f := newIndexerFixture(t)
	p := f.write(t, "gone.md", recipeText("d", "1"))
	f.write(t, "stays.md", recipeText("d", "2"))
	f.rescan(t)
	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
	f.clock.now = f.clock.now.Add(time.Hour)
	rep := f.rescan(t)
	wantCounts(t, rep, 0, 1, 1)
	gone := f.row(t, "gone")
	if gone.RemovedAt == nil || !gone.RemovedAt.Equal(f.clock.now) {
		t.Errorf("removed_at = %v, want %v", gone.RemovedAt, f.clock.now)
	}
	if f.row(t, "stays").RemovedAt != nil {
		t.Error("present file marked removed")
	}
	if rep := f.rescan(t); rep.Removed != 0 {
		t.Errorf("third rescan Removed = %d, want 0 (already stamped)", rep.Removed)
	}
}

func TestRescan_FirstIndexSetsLastScheduledForNow(t *testing.T) {
	f := newIndexerFixture(t)
	f.write(t, "sched.md", recipeText("d", "1"))
	f.write(t, "manual.md", strings.Replace(recipeText("d", "1"), `schedule: "0 9 * * *"`, "manual: true", 1))
	f.rescan(t)
	if a := f.row(t, "sched"); a.LastScheduledFor == nil || !a.LastScheduledFor.Equal(f.clock.now) {
		t.Errorf("schedule last_scheduled_for = %v, want %v", a.LastScheduledFor, f.clock.now)
	}
	if a := f.row(t, "manual"); a.LastScheduledFor != nil {
		t.Errorf("manual last_scheduled_for = %v, want NULL", a.LastScheduledFor)
	}
	// A later rescan of a changed file keeps the schedule point.
	first := f.clock.now
	f.clock.now = first.Add(time.Hour)
	f.write(t, "sched.md", recipeText("edited", "1"))
	f.rescan(t)
	if a := f.row(t, "sched"); !a.LastScheduledFor.Equal(first) {
		t.Errorf("after an edit last_scheduled_for = %v, want %v", a.LastScheduledFor, first)
	}
}

// TestRescan_RunnableAgainRestartsScheduleNow: a row a rescan makes runnable
// again (approval_hash reverted to the confirmed one, its file back after a
// removal, its parse error fixed) gets last_scheduled_for = now — no catch-up
// for the window it was not runnable.
func TestRescan_RunnableAgainRestartsScheduleNow(t *testing.T) {
	good := recipeText("d", `log("ok")`)
	cases := []struct {
		name    string
		breakIt func(t *testing.T, f *indexerFixture, path string)
	}{
		{"approval hash reverted", func(t *testing.T, f *indexerFixture, _ string) {
			f.write(t, "job.md", recipeText("d", `log("evil")`))
		}},
		{"file came back", func(t *testing.T, _ *indexerFixture, path string) {
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
		}},
		{"parse error fixed", func(t *testing.T, f *indexerFixture, _ string) {
			f.write(t, "job.md", "---\nname: x\n---\n")
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newIndexerFixture(t)
			path := f.write(t, "job.md", good)
			f.rescan(t)
			f.confirmEnable(t, "job")
			confirmedAt := f.clock.now

			f.clock.now = confirmedAt.Add(48 * time.Hour)
			tc.breakIt(t, f, path)
			f.rescan(t)
			if f.row(t, "job").Runnable() {
				t.Fatal("broken row still runnable")
			}
			if a := f.row(t, "job"); !a.LastScheduledFor.Equal(confirmedAt) {
				t.Errorf("not-runnable rescan moved last_scheduled_for to %v", a.LastScheduledFor)
			}

			f.clock.now = confirmedAt.Add(96 * time.Hour)
			f.write(t, "job.md", good)
			f.rescan(t)
			a := f.row(t, "job")
			if !a.Runnable() {
				t.Fatal("restored row not runnable")
			}
			if a.LastScheduledFor == nil || !a.LastScheduledFor.Equal(f.clock.now) {
				t.Errorf("last_scheduled_for = %v, want now %v (no catch-up)", a.LastScheduledFor, f.clock.now)
			}
		})
	}
}

func TestRescan_TriggerBecomesScheduleRestartsNow(t *testing.T) {
	f := newIndexerFixture(t)
	manual := strings.Replace(recipeText("d", "1"), `schedule: "0 9 * * *"`, "manual: true", 1)
	f.write(t, "job.md", manual)
	f.rescan(t)
	f.confirmEnable(t, "job")
	f.clock.now = f.clock.now.Add(30 * 24 * time.Hour)
	f.write(t, "job.md", recipeText("d", "1"))
	f.rescan(t)
	if a := f.row(t, "job"); !a.Runnable() || !a.LastScheduledFor.Equal(f.clock.now) {
		t.Errorf("runnable=%v last_scheduled_for=%v, want runnable and %v", a.Runnable(), a.LastScheduledFor, f.clock.now)
	}
}

func TestRescan_SlugTakenAtOtherPathIsSkipped(t *testing.T) {
	f := newIndexerFixture(t)
	elsewhere := filepath.Join(t.TempDir(), "old", "mail.md")
	id, err := f.d.UpsertAutomationIndex(db.Automation{Slug: "mail", Scope: "personal", Path: elsewhere})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.MarkAutomationsRemovedExcept("personal", 0, nil, f.clock.now); err != nil {
		t.Fatal(err)
	}
	path := f.write(t, "mail.md", recipeText("d", "1"))
	rep := f.rescan(t)
	wantCounts(t, rep, 0, 0, 0)
	if len(rep.Skipped) != 1 || rep.Skipped[0].Path != path {
		t.Fatalf("Skipped = %+v, want mail.md", rep.Skipped)
	}
	reason := rep.Skipped[0].Reason
	for _, want := range []string{`slug "mail" is already used`, elsewhere, "removed", "automations delete"} {
		if !strings.Contains(reason, want) {
			t.Errorf("reason %q lacks %q", reason, want)
		}
	}
	if strings.Contains(reason, "UNIQUE") {
		t.Errorf("reason leaks the raw constraint error: %q", reason)
	}
	if a := f.row(t, "mail"); a.ID != id || a.Path != elsewhere {
		t.Errorf("row = %d at %s, want the old row untouched", a.ID, a.Path)
	}
}

func TestRescan_CanonicalisesSymlinkedFolder(t *testing.T) {
	f := newIndexerFixture(t)
	f.write(t, "mail.md", recipeText("d", "1"))
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(f.dir, link); err != nil {
		t.Fatal(err)
	}
	f.rescan(t)
	rep, err := f.ix.RescanFolder(context.Background(), Scope{Kind: ScopePersonal}, link)
	if err != nil {
		t.Fatal(err)
	}
	wantCounts(t, rep, 0, 1, 0)
	if p := f.row(t, "mail").Path; p != filepath.Join(f.dir, "mail.md") {
		t.Errorf("path = %s, want under the resolved folder %s", p, f.dir)
	}
}

func TestRescan_WorkbenchScope(t *testing.T) {
	f := newIndexerFixture(t)
	res, err := f.d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', ?)`, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	wb, _ := res.LastInsertId()
	dir := WorkbenchDir(t.TempDir())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "triage.md"), []byte(recipeText("d", "1")), 0o644); err != nil {
		t.Fatal(err)
	}
	rep, err := f.ix.RescanFolder(context.Background(), Scope{Kind: ScopeWorkbench, WorkbenchID: wb}, dir)
	if err != nil {
		t.Fatal(err)
	}
	wantCounts(t, rep, 1, 0, 0)
	a, err := f.d.GetAutomationBySlug("workbench", wb, "triage")
	if err != nil {
		t.Fatal(err)
	}
	if a.ProjectID != wb || a.ParseError != "" {
		t.Errorf("project_id=%d parse_error=%q", a.ProjectID, a.ParseError)
	}
	// The personal rescan does not touch the workbench's rows.
	if rep := f.rescan(t); rep.Removed != 0 {
		t.Errorf("personal rescan removed %d rows", rep.Removed)
	}
}

func TestRescan_RefusesInvalidScopeAndCancelledContext(t *testing.T) {
	f := newIndexerFixture(t)
	for _, sc := range []Scope{{}, {Kind: ScopeWorkbench}, {Kind: ScopePersonal, WorkbenchID: 3}} {
		if _, err := f.ix.RescanFolder(context.Background(), sc, f.dir); err == nil {
			t.Errorf("scope %+v accepted", sc)
		}
	}
	f.write(t, "mail.md", recipeText("d", "1"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := f.ix.RescanPersonal(ctx); !errors.Is(err, context.Canceled) {
		t.Errorf("cancelled rescan err = %v, want context.Canceled", err)
	}
}

func TestIndexer_ChangedTracksFolder(t *testing.T) {
	f := newIndexerFixture(t)
	dir := PersonalDir(f.ws)
	steps := []struct {
		name string
		act  func()
		want bool
	}{
		{"never scanned", func() {}, true},
		{"scanned missing folder", func() { f.rescan(t) }, false},
		{"folder created with a file", func() { f.write(t, "a.md", recipeText("d", "1")) }, true},
		{"rescanned", func() { f.rescan(t) }, false},
		{"file rewritten in place", func() { f.write(t, "a.md", recipeText("longer description", "1")) }, true},
		{"rescanned again", func() { f.rescan(t) }, false},
		{"file chmod only (ctime)", func() {
			if err := os.Chmod(filepath.Join(f.dir, "a.md"), 0o600); err != nil {
				t.Fatal(err)
			}
		}, true},
		{"rescanned after chmod", func() { f.rescan(t) }, false},
	}
	for _, s := range steps {
		s.act()
		if got := f.ix.Changed(dir); got != s.want {
			t.Errorf("%s: Changed = %v, want %v", s.name, got, s.want)
		}
	}
}

func TestTriggerSpecJSON_Shapes(t *testing.T) {
	cases := []struct {
		trigger Trigger
		want    string
	}{
		{Trigger{Kind: TriggerSchedule, Schedule: "0 9 * * *"}, `{"schedule":"0 9 * * *"}`},
		{Trigger{Kind: TriggerButton, Button: &ButtonTrigger{Label: "Go"}}, `{"button":{"label":"Go","confirm":false}}`},
		{Trigger{Kind: TriggerEvent, Event: &EventTrigger{Type: "jira.issue_changed", Where: map[string]string{"project": "ACME"}}},
			`{"event":{"type":"jira.issue_changed","where":{"project":"ACME"}}}`},
		{Trigger{Kind: TriggerManual}, `{"manual":true}`},
	}
	for _, tc := range cases {
		got, err := triggerSpecJSON(tc.trigger)
		if err != nil || got != tc.want {
			t.Errorf("%s: got %q, %v; want %q", tc.trigger.Kind, got, err, tc.want)
		}
	}
	if _, err := triggerSpecJSON(Trigger{}); err == nil {
		t.Error("empty trigger kind encoded")
	}
}

func TestRescan_OversizedFileHashesWholeFile(t *testing.T) {
	f := newIndexerFixture(t)
	head := strings.Repeat("x", MaxRecipeBytes+10)
	f.write(t, "big.md", head+"A")
	f.rescan(t)
	first := f.row(t, "big").ContentHash
	if first != ContentHash([]byte(head+"A")) {
		t.Errorf("content_hash = %s, want the hash of the whole file", first)
	}
	f.write(t, "big.md", head+"B") // differs only past the cap
	if rep := f.rescan(t); rep.Indexed != 1 {
		t.Errorf("edit past the cap: %+v, want Indexed=1", rep)
	}
	if f.row(t, "big").ContentHash == first {
		t.Error("an edit past the cap kept the content hash")
	}
}

// rescanWithin fails the test instead of hanging when a rescan blocks.
func rescanWithin(t *testing.T, f *indexerFixture, d time.Duration) RescanReport {
	t.Helper()
	type result struct {
		rep RescanReport
		err error
	}
	done := make(chan result, 1)
	go func() {
		rep, err := f.ix.RescanPersonal(context.Background())
		done <- result{rep, err}
	}()
	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("RescanPersonal: %v", r.err)
		}
		return r.rep
	case <-time.After(d):
		t.Fatalf("rescan still blocked after %s", d)
		return RescanReport{}
	}
}

func TestRescan_SymlinksAndSpecialFilesSkipped(t *testing.T) {
	f := newIndexerFixture(t)
	f.write(t, "real.md", recipeText("d", "1"))
	outside := filepath.Join(t.TempDir(), "outside.md")
	if err := os.WriteFile(outside, []byte(recipeText("d", "2")), 0o644); err != nil {
		t.Fatal(err)
	}
	links := map[string]string{
		"inside.md":   filepath.Join(f.dir, "real.md"),
		"outside.md":  outside,
		"dangling.md": filepath.Join(f.dir, "nowhere.md"),
	}
	for name, target := range links {
		if err := os.Symlink(target, filepath.Join(f.dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	if err := syscall.Mkfifo(filepath.Join(f.dir, "pipe.md"), 0o644); err != nil {
		t.Fatal(err)
	}
	rep := rescanWithin(t, f, 10*time.Second)
	wantCounts(t, rep, 1, 0, 0)
	skipped := map[string]bool{}
	for _, n := range rep.Skipped {
		skipped[filepath.Base(n.Path)] = n.Reason == specialEntryReason
	}
	for _, name := range []string{"inside.md", "outside.md", "dangling.md", "pipe.md"} {
		if !skipped[name] {
			t.Errorf("%s not skipped with the special-entry note (Skipped = %+v)", name, rep.Skipped)
		}
	}
	all, err := f.d.ListAutomations(db.AutomationFilter{IncludeRemoved: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].Slug != "real" {
		t.Errorf("rows = %+v, want only real", all)
	}
	if _, _, _, err := readRecipeFile(filepath.Join(f.dir, "pipe.md"), bigFileHash{}); err == nil {
		t.Error("readRecipeFile read a FIFO")
	}
}

func TestRescan_FileReplacedBySymlinkIsRemoved(t *testing.T) {
	f := newIndexerFixture(t)
	p := f.write(t, "job.md", recipeText("d", "1"))
	f.rescan(t)
	other := filepath.Join(t.TempDir(), "job.md")
	if err := os.WriteFile(other, []byte(recipeText("d", "evil")), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, p); err != nil {
		t.Fatal(err)
	}
	rep := f.rescan(t)
	if rep.Removed != 1 || f.row(t, "job").RemovedAt == nil {
		t.Errorf("report %+v: a recipe replaced by a symlink must be removed, not re-read", rep)
	}
}

func TestRescan_UnreadableFileKeepsRow(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a 000 file")
	}
	f := newIndexerFixture(t)
	p := f.write(t, "job.md", recipeText("d", "1"))
	f.rescan(t)
	before := f.row(t, "job")
	if err := os.Chmod(p, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(p, 0o644) })
	rep := f.rescan(t)
	wantCounts(t, rep, 0, 0, 0)
	if len(rep.Skipped) != 1 || !strings.Contains(rep.Skipped[0].Reason, "cannot read the recipe") {
		t.Errorf("Skipped = %+v, want the unreadable file", rep.Skipped)
	}
	after := f.row(t, "job")
	if after.RemovedAt != nil || after.ContentHash != before.ContentHash {
		t.Errorf("unreadable file: removed_at=%v, content changed=%v; want the row kept as indexed",
			after.RemovedAt, after.ContentHash != before.ContentHash)
	}
}

// TestRescan_StaleIndexerCannotRewindSchedule simulates two indexers
// interleaved: A restores a confirmed recipe (primes, makes it runnable), the
// scheduler advances last_scheduled_for, then B — working from the snapshot
// it took before A's write — applies the same restore. B must not rewind the
// scheduler's point.
func TestRescan_StaleIndexerCannotRewindSchedule(t *testing.T) {
	f := newIndexerFixture(t)
	good := recipeText("d", `log("ok")`)
	path := f.write(t, "job.md", good)
	f.rescan(t)
	f.confirmEnable(t, "job")
	f.write(t, "job.md", recipeText("d", `log("evil")`))
	f.rescan(t)
	f.write(t, "job.md", good)

	stale := *f.row(t, "job") // B's snapshot: not runnable
	cand, err := (&folderScan{ix: f.ix, scope: Scope{Kind: ScopePersonal}, dir: f.dir}).
		candidate("job", path, []byte(good), ContentHash([]byte(good)))
	if err != nil {
		t.Fatal(err)
	}

	f.clock.now = f.clock.now.Add(time.Hour)
	f.rescan(t) // indexer A
	if !f.row(t, "job").Runnable() {
		t.Fatal("A did not restore the row")
	}
	advanced := f.clock.now.Add(2 * time.Hour)
	if err := f.d.SetAutomationSchedule(stale.ID, &advanced, nil); err != nil {
		t.Fatal(err)
	}

	b := &folderScan{ix: f.ix, scope: Scope{Kind: ScopePersonal}, dir: f.dir, now: f.clock.now.Add(time.Hour)}
	if err := b.update(stale, cand); err != nil {
		t.Fatal(err)
	}
	if a := f.row(t, "job"); a.LastScheduledFor == nil || !a.LastScheduledFor.Equal(advanced) {
		t.Errorf("last_scheduled_for = %v, want the scheduler's %v", a.LastScheduledFor, advanced)
	}
}

func TestIndexer_ChangedSeesDBDeleteThatFreesSlug(t *testing.T) {
	f := newIndexerFixture(t)
	old, err := f.d.UpsertAutomationIndex(db.Automation{Slug: "mail", Scope: "personal", Path: filepath.Join(t.TempDir(), "mail.md")})
	if err != nil {
		t.Fatal(err)
	}
	f.write(t, "mail.md", recipeText("d", "1"))
	if rep := f.rescan(t); len(rep.Skipped) != 1 {
		t.Fatalf("Skipped = %+v, want the slug collision", rep.Skipped)
	}
	dir := PersonalDir(f.ws)
	if f.ix.Changed(dir) {
		t.Fatal("Changed right after a rescan")
	}
	if err := f.d.DeleteAutomation(old); err != nil {
		t.Fatal(err)
	}
	if !f.ix.Changed(dir) {
		t.Fatal("Changed missed the delete that freed the slug")
	}
	if rep := f.rescan(t); rep.Indexed != 1 || len(rep.Skipped) != 0 {
		t.Errorf("rescan after the delete: %+v, want mail indexed", rep)
	}
}

// TestRescan_OversizedUnchangedFileIsNotReread: an oversized file whose
// lstat size and mtime are unchanged keeps its stored content hash without
// being read past the cap — shown by an edit past the cap that keeps both.
func TestRescan_OversizedUnchangedFileIsNotReread(t *testing.T) {
	f := newIndexerFixture(t)
	head := strings.Repeat("x", MaxRecipeBytes+10)
	p := f.write(t, "big.md", head+"A")
	f.rescan(t)
	first := f.row(t, "big").ContentHash
	fi, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	f.write(t, "big.md", head+"B")
	if err := os.Chtimes(p, fi.ModTime(), fi.ModTime()); err != nil {
		t.Fatal(err)
	}
	if rep := f.rescan(t); rep.Unchanged != 1 || f.row(t, "big").ContentHash != first {
		t.Errorf("same size+mtime: %+v, hash changed=%v; want the cached hash reused", rep, f.row(t, "big").ContentHash != first)
	}
	later := fi.ModTime().Add(time.Minute)
	if err := os.Chtimes(p, later, later); err != nil {
		t.Fatal(err)
	}
	f.rescan(t)
	if got := f.row(t, "big").ContentHash; got != ContentHash([]byte(head+"B")) {
		t.Errorf("after an mtime change content_hash = %s, want the re-read hash", got)
	}
}
