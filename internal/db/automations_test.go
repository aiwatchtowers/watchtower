package db

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

// seedAutomationRow upserts a parsed personal automation at path with the
// given approval hash.
func seedAutomationRow(t *testing.T, d *DB, slug, path, approval string) int64 {
	t.Helper()
	id, err := d.UpsertAutomationIndex(Automation{
		Slug: slug, Scope: "personal", Path: path, Name: "Acme " + slug,
		TriggerKind: "manual", TriggerSpec: `{"manual":true}`, MissedPolicy: "run_once",
		Concurrency: 1, BudgetTokens: 50000, BudgetMinutes: 5, PauseTimeoutHours: 72,
		PermissionsJSON: `["llm"]`, OutputsJSON: `["inbox"]`,
		RecipeText: "---\nname: x\n---\n", ContentHash: "c-" + approval, ApprovalHash: approval,
	})
	if err != nil {
		t.Fatalf("UpsertAutomationIndex(%s): %v", path, err)
	}
	return id
}

func mustGetAutomation(t *testing.T, d *DB, id int64) *Automation {
	t.Helper()
	a, err := d.GetAutomation(id)
	if err != nil {
		t.Fatalf("GetAutomation(%d): %v", id, err)
	}
	return a
}

func TestMigration00113_AutomationTables(t *testing.T) {
	d := openTestDB(t)
	for _, name := range []string{
		"automations", "automation_runs", "automation_run_steps", "automation_state", "automation_outputs",
		"idx_automations_scope_slug", "idx_automation_runs_automation_status", "idx_automation_runs_status_queued",
		"idx_automation_runs_event_cycle", "idx_automation_runs_queued_trigger", "idx_automation_runs_rerun_of",
		"idx_automation_runs_started_at",
		"idx_automation_outputs_kind", "idx_automation_outputs_automation", "idx_automation_outputs_run",
	} {
		var got string
		if err := d.QueryRow(`SELECT name FROM sqlite_master WHERE name = ?`, name).Scan(&got); err != nil {
			t.Errorf("%s missing after migration: %v", name, err)
		}
	}

	wb, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO automations (slug, scope, project_id, path) VALUES ('a', 'workbench', NULL, '/w/a.md')`); err == nil {
		t.Error("workbench row with NULL project_id inserted; want CHECK error")
	}
	if _, err := d.Exec(`INSERT INTO automations (slug, scope, project_id, path) VALUES ('a', 'personal', ?, '/p/a.md')`, wb); err == nil {
		t.Error("personal row with a project_id inserted; want CHECK error")
	}
	if _, err := d.Exec(`INSERT INTO automations (slug, scope, project_id, path) VALUES ('a', 'workbench', ?, '/w/a.md')`, wb); err != nil {
		t.Errorf("valid workbench row refused: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO automations (slug, scope, path) VALUES ('a', 'personal', '/p/a.md')`); err != nil {
		t.Errorf("valid personal row refused: %v", err)
	}
}

func TestAutomationIndex_UpsertKeepsOwnerColumns(t *testing.T) {
	d := openTestDB(t)
	path := filepath.Join(t.TempDir(), "digest.md")
	id := seedAutomationRow(t, d, "digest", path, "h1")
	if err := d.ConfirmAutomation(id, "h1", time.Now()); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 14, 9, 30, 0, 0, time.UTC)
	if err := d.SetAutomationEnabled(id, true, now); err != nil {
		t.Fatal(err)
	}

	again, err := d.UpsertAutomationIndex(Automation{
		Slug: "digest", Scope: "personal", Path: path, Name: "Renamed",
		TriggerKind: "manual", RecipeText: "new text", ContentHash: "c2", ApprovalHash: "h1",
		ConfirmedHash: "forged", Enabled: false,
	})
	if err != nil {
		t.Fatal(err)
	}
	if again != id {
		t.Fatalf("upsert by path returned id %d, want %d", again, id)
	}
	a := mustGetAutomation(t, d, id)
	if a.ConfirmedHash != "h1" || !a.Enabled || a.LastScheduledFor == nil || !a.LastScheduledFor.Equal(now) {
		t.Errorf("owner columns changed: confirmed=%q enabled=%v last=%v", a.ConfirmedHash, a.Enabled, a.LastScheduledFor)
	}
	if a.RecipeText != "new text" || a.Name != "Renamed" || a.ContentHash != "c2" {
		t.Errorf("index columns not updated: %+v", a)
	}
	if !a.Runnable() {
		t.Error("confirmed, enabled row with the same approval hash is not runnable")
	}
}

func TestAutomationIndex_InsertNeverSetsOwnerColumns(t *testing.T) {
	d := openTestDB(t)
	now := time.Now().UTC()
	id, err := d.UpsertAutomationIndex(Automation{
		Slug: "x", Scope: "personal", Path: filepath.Join(t.TempDir(), "x.md"),
		ApprovalHash: "h", ConfirmedHash: "h", Enabled: true, LastScheduledFor: &now,
	})
	if err != nil {
		t.Fatal(err)
	}
	a := mustGetAutomation(t, d, id)
	if a.ConfirmedHash != "" || a.Enabled || a.LastScheduledFor != nil {
		t.Errorf("new row took owner columns from the caller: %+v", a)
	}
	// Zero numeric fields store the column defaults.
	if a.Concurrency != 1 || a.BudgetTokens != 50000 || a.BudgetMinutes != 5 || a.PauseTimeoutHours != 72 ||
		a.MissedPolicy != "run_once" || a.TriggerSpec != "{}" || a.PermissionsJSON != "[]" || a.OutputsJSON != "[]" {
		t.Errorf("zero fields did not store the column defaults: %+v", a)
	}
}

func TestAutomationIndex_ConfirmRefusesStaleHash(t *testing.T) {
	d := openTestDB(t)
	id := seedAutomationRow(t, d, "digest", filepath.Join(t.TempDir(), "digest.md"), "h1")
	if err := d.ConfirmAutomation(id, "other", time.Now()); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("ConfirmAutomation(other) = %v, want ErrHashMismatch", err)
	}
	if err := d.ConfirmAutomation(id, "", time.Now()); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("ConfirmAutomation(\"\") = %v, want ErrHashMismatch", err)
	}
	if got := mustGetAutomation(t, d, id).ConfirmedHash; got != "" {
		t.Errorf("confirmed_hash = %q after refused confirms, want ''", got)
	}
	if err := d.ConfirmAutomation(id+100, "h1", time.Now()); !errors.Is(err, ErrAutomationNotFound) {
		t.Errorf("ConfirmAutomation(missing) = %v, want ErrAutomationNotFound", err)
	}
}

func TestAutomationIndex_RunnableTable(t *testing.T) {
	removed := time.Now()
	ok := Automation{Enabled: true, ApprovalHash: "h", ConfirmedHash: "h"}
	cases := []struct {
		name string
		mut  func(*Automation)
		want bool
	}{
		{"parse error", func(a *Automation) { a.ParseError = "bad" }, false},
		{"disabled", func(a *Automation) { a.Enabled = false }, false},
		{"removed", func(a *Automation) { a.RemovedAt = &removed }, false},
		{"unconfirmed", func(a *Automation) { a.ConfirmedHash = "" }, false},
		{"unconfirmed empty approval", func(a *Automation) { a.ConfirmedHash, a.ApprovalHash = "", "" }, false},
		{"confirmed but changed", func(a *Automation) { a.ApprovalHash = "h2" }, false},
		{"ok", func(*Automation) {}, true},
	}
	for _, c := range cases {
		a := ok
		c.mut(&a)
		if got := a.Runnable(); got != c.want {
			t.Errorf("%s: Runnable() = %v, want %v", c.name, got, c.want)
		}
	}

	// The SQL predicate of RunnableOnly agrees with Runnable().
	d := openTestDB(t)
	dir := t.TempDir()
	good := seedAutomationRow(t, d, "good", filepath.Join(dir, "good.md"), "h")
	changed := seedAutomationRow(t, d, "changed", filepath.Join(dir, "changed.md"), "h")
	disabled := seedAutomationRow(t, d, "disabled", filepath.Join(dir, "disabled.md"), "h")
	seedAutomationRow(t, d, "unconfirmed", filepath.Join(dir, "unconfirmed.md"), "h")
	for _, id := range []int64{good, changed, disabled} {
		if err := d.ConfirmAutomation(id, "h", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []int64{good, changed} {
		if err := d.SetAutomationEnabled(id, true, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := d.Exec(`UPDATE automations SET approval_hash = 'h2' WHERE id = ?`, changed); err != nil {
		t.Fatal(err)
	}
	list, err := d.ListAutomations(AutomationFilter{RunnableOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].ID != good {
		t.Errorf("RunnableOnly listed %+v, want only id %d", list, good)
	}
}

func TestAutomationIndex_EnableSetsLastScheduledForNow(t *testing.T) {
	d := openTestDB(t)
	id := seedAutomationRow(t, d, "digest", filepath.Join(t.TempDir(), "digest.md"), "h1")
	now := time.Now().Truncate(time.Second)
	if err := d.SetAutomationEnabled(id, true, now); err != nil {
		t.Fatal(err)
	}
	a := mustGetAutomation(t, d, id)
	if !a.Enabled || a.LastScheduledFor == nil || !a.LastScheduledFor.Equal(now) {
		t.Fatalf("after enable: enabled=%v last_scheduled_for=%v, want %v", a.Enabled, a.LastScheduledFor, now)
	}
	// Enabling an already enabled row keeps its schedule point.
	if err := d.SetAutomationEnabled(id, true, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if a = mustGetAutomation(t, d, id); !a.LastScheduledFor.Equal(now) {
		t.Errorf("re-enable moved last_scheduled_for to %v, want %v", a.LastScheduledFor, now)
	}
	// Disabling keeps it; enabling again moves it to the new now.
	if err := d.SetAutomationEnabled(id, false, now.Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if a = mustGetAutomation(t, d, id); a.Enabled || !a.LastScheduledFor.Equal(now) {
		t.Errorf("after disable: enabled=%v last=%v", a.Enabled, a.LastScheduledFor)
	}
	later := now.Add(3 * time.Hour)
	if err := d.SetAutomationEnabled(id, true, later); err != nil {
		t.Fatal(err)
	}
	if a = mustGetAutomation(t, d, id); !a.LastScheduledFor.Equal(later) {
		t.Errorf("enable after disable: last=%v, want %v", a.LastScheduledFor, later)
	}
	if err := d.SetAutomationEnabled(id+100, true, now); !errors.Is(err, ErrAutomationNotFound) {
		t.Errorf("SetAutomationEnabled(missing) = %v, want ErrAutomationNotFound", err)
	}
}

func TestAutomationIndex_MarkRemovedExcept(t *testing.T) {
	d := openTestDB(t)
	dir := t.TempDir()
	keepPath, gonePath := filepath.Join(dir, "keep.md"), filepath.Join(dir, "gone.md")
	keep := seedAutomationRow(t, d, "keep", keepPath, "h")
	gone := seedAutomationRow(t, d, "gone", gonePath, "h")
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	other, err := d.UpsertAutomationIndex(Automation{Slug: "gone", Scope: "workbench", ProjectID: wb, Path: filepath.Join(dir, "wb", "gone.md")})
	if err != nil {
		t.Fatal(err)
	}

	now := time.Now().Truncate(time.Second)
	n, err := d.MarkAutomationsRemovedExcept("personal", 0, []string{keepPath}, now)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("marked %d rows, want 1", n)
	}
	assertRemovedStamps(t, d, now, gone, keep, other)
	// A second pass does not re-stamp an already removed row.
	if n, err = d.MarkAutomationsRemovedExcept("personal", 0, []string{keepPath}, now.Add(time.Hour)); err != nil || n != 0 {
		t.Errorf("second pass = (%d, %v), want (0, nil)", n, err)
	}
	assertRemovedListing(t, d, keep)

	seedAutomationRow(t, d, "gone", gonePath, "h")
	if a := mustGetAutomation(t, d, gone); a.RemovedAt != nil {
		t.Errorf("re-upsert left removed_at %v", a.RemovedAt)
	}

	// An empty keep list removes every row of the scope.
	if n, err = d.MarkAutomationsRemovedExcept("personal", 0, nil, now); err != nil || n != 2 {
		t.Errorf("empty keep list = (%d, %v), want (2, nil)", n, err)
	}
}

// assertRemovedStamps checks that only gone carries removed_at = now; keep
// (still on disk) and other (another scope) stay unstamped.
func assertRemovedStamps(t *testing.T, d *DB, now time.Time, gone, keep, other int64) {
	t.Helper()
	if a := mustGetAutomation(t, d, gone); a.RemovedAt == nil || !a.RemovedAt.Equal(now) {
		t.Errorf("gone.removed_at = %v, want %v", a.RemovedAt, now)
	}
	if a := mustGetAutomation(t, d, keep); a.RemovedAt != nil {
		t.Errorf("kept row got removed_at %v", a.RemovedAt)
	}
	if a := mustGetAutomation(t, d, other); a.RemovedAt != nil {
		t.Errorf("another scope's row got removed_at %v", a.RemovedAt)
	}
}

// assertRemovedListing checks that the default personal list hides removed
// rows (only keep) and IncludeRemoved shows both personal rows.
func assertRemovedListing(t *testing.T, d *DB, keep int64) {
	t.Helper()
	listed, err := d.ListAutomations(AutomationFilter{Scope: "personal"})
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].ID != keep {
		t.Errorf("default list = %+v, want only the kept row", listed)
	}
	if listed, err = d.ListAutomations(AutomationFilter{Scope: "personal", IncludeRemoved: true}); err != nil || len(listed) != 2 {
		t.Errorf("IncludeRemoved list = %d rows (%v), want 2", len(listed), err)
	}
}

func TestAutomationIndex_SlugUniquePerScope(t *testing.T) {
	d := openTestDB(t)
	dir := t.TempDir()
	wb1, err := d.CreateWorkbench("acme one", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	wb2, err := d.CreateWorkbench("acme two", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for i, a := range []Automation{
		{Slug: "triage", Scope: "personal", Path: filepath.Join(dir, "p", "triage.md")},
		{Slug: "triage", Scope: "workbench", ProjectID: wb1, Path: filepath.Join(dir, "w1", "triage.md")},
		{Slug: "triage", Scope: "workbench", ProjectID: wb2, Path: filepath.Join(dir, "w2", "triage.md")},
	} {
		if _, err := d.UpsertAutomationIndex(a); err != nil {
			t.Fatalf("row %d refused: %v", i, err)
		}
	}
	if _, err := d.UpsertAutomationIndex(Automation{Slug: "triage", Scope: "workbench", ProjectID: wb1, Path: filepath.Join(dir, "w1b", "triage.md")}); err == nil {
		t.Error("duplicate slug in workbench 1 accepted")
	}
	if _, err := d.UpsertAutomationIndex(Automation{Slug: "triage", Scope: "personal", Path: filepath.Join(dir, "p2", "triage.md")}); err == nil {
		t.Error("duplicate personal slug accepted")
	}
	assertSlugLookupsPerScope(t, d, wb1, wb2)
}

// assertSlugLookupsPerScope checks GetAutomationBySlug and ListAutomations
// resolve the same slug per scope and workbench.
func assertSlugLookupsPerScope(t *testing.T, d *DB, wb1, wb2 int64) {
	t.Helper()
	got, err := d.GetAutomationBySlug("workbench", wb2, "triage")
	if err != nil || got.ProjectID != wb2 || got.Scope != "workbench" {
		t.Errorf("GetAutomationBySlug(workbench %d) = %+v, %v", wb2, got, err)
	}
	if got, err = d.GetAutomationBySlug("personal", 0, "triage"); err != nil || got.ProjectID != 0 {
		t.Errorf("GetAutomationBySlug(personal) = %+v, %v", got, err)
	}
	if _, err = d.GetAutomationBySlug("personal", 0, "nope"); !errors.Is(err, ErrAutomationNotFound) {
		t.Errorf("GetAutomationBySlug(missing) = %v, want ErrAutomationNotFound", err)
	}
	list, err := d.ListAutomations(AutomationFilter{Scope: "workbench", ProjectID: wb1})
	if err != nil || len(list) != 1 || list[0].ProjectID != wb1 {
		t.Errorf("ListAutomations(workbench %d) = %+v, %v", wb1, list, err)
	}
}

func TestAutomationIndex_GetMissingIsNotFound(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.GetAutomation(42); !errors.Is(err, ErrAutomationNotFound) {
		t.Errorf("GetAutomation(missing) = %v, want ErrAutomationNotFound", err)
	}
	if err := d.DeleteAutomation(42); !errors.Is(err, ErrAutomationNotFound) {
		t.Errorf("DeleteAutomation(missing) = %v, want ErrAutomationNotFound", err)
	}
	if err := d.SetAutomationSchedule(42, nil, nil); !errors.Is(err, ErrAutomationNotFound) {
		t.Errorf("SetAutomationSchedule(missing) = %v, want ErrAutomationNotFound", err)
	}
}

func TestAutomationIndex_ScheduleAndFilterAndDelete(t *testing.T) {
	d := openTestDB(t)
	dir := t.TempDir()
	id := seedAutomationRow(t, d, "b-sched", filepath.Join(dir, "b.md"), "h")
	if _, err := d.UpsertAutomationIndex(Automation{Slug: "a-btn", Scope: "personal", Path: filepath.Join(dir, "a.md"), TriggerKind: "button"}); err != nil {
		t.Fatal(err)
	}
	assertScheduleRoundTrip(t, d, id)
	assertListOrderAndTriggerFilter(t, d)
	assertDeleteCascades(t, d, id)
}

// assertScheduleRoundTrip sets last/next schedule times, reads them back, then
// clears next_run_at with nil.
func assertScheduleRoundTrip(t *testing.T, d *DB, id int64) {
	t.Helper()
	last := time.Date(2026, 10, 14, 8, 0, 0, 0, time.UTC)
	next := last.Add(time.Hour)
	if err := d.SetAutomationSchedule(id, &last, &next); err != nil {
		t.Fatal(err)
	}
	a := mustGetAutomation(t, d, id)
	if !a.LastScheduledFor.Equal(last) || !a.NextRunAt.Equal(next) {
		t.Errorf("schedule = %v / %v, want %v / %v", a.LastScheduledFor, a.NextRunAt, last, next)
	}
	if err := d.SetAutomationSchedule(id, &last, nil); err != nil {
		t.Fatal(err)
	}
	if a = mustGetAutomation(t, d, id); a.NextRunAt != nil {
		t.Errorf("next_run_at = %v after nil, want NULL", a.NextRunAt)
	}
}

// assertListOrderAndTriggerFilter checks slug ordering and the trigger filter
// over the two seeded rows (a-btn, b-sched).
func assertListOrderAndTriggerFilter(t *testing.T, d *DB) {
	t.Helper()
	all, err := d.ListAutomations(AutomationFilter{})
	if err != nil || len(all) != 2 || all[0].Slug != "a-btn" || all[1].Slug != "b-sched" {
		t.Errorf("ListAutomations() = %+v, %v; want slug order", all, err)
	}
	btn, err := d.ListAutomations(AutomationFilter{TriggerKind: "button"})
	if err != nil || len(btn) != 1 || btn[0].Slug != "a-btn" {
		t.Errorf("TriggerKind filter = %+v, %v", btn, err)
	}
}

// assertDeleteCascades checks DeleteAutomation cascades to runs, steps, state
// and outputs.
func assertDeleteCascades(t *testing.T, d *DB, id int64) {
	t.Helper()
	res, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger) VALUES (?, 'manual')`, id)
	if err != nil {
		t.Fatal(err)
	}
	runID, _ := res.LastInsertId()
	for _, q := range []string{
		`INSERT INTO automation_run_steps (run_id, seq, kind, status) VALUES (?, 1, 'log', 'ok')`,
		`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body) SELECT automation_id, id, 'inbox', 't', 'b' FROM automation_runs WHERE id = ?`,
		`INSERT INTO automation_state (automation_id, run_id) SELECT automation_id, id FROM automation_runs WHERE id = ?`,
	} {
		if _, err := d.Exec(q, runID); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	if err := d.DeleteAutomation(id); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"automation_runs", "automation_run_steps", "automation_outputs", "automation_state"} {
		var n int
		if err := d.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Errorf("%s has %d rows after DeleteAutomation, want 0", table, n)
		}
	}
}

func TestMigration00113_PartialUniqueIndexes(t *testing.T) {
	d := openTestDB(t)
	id := seedAutomationRow(t, d, "digest", filepath.Join(t.TempDir(), "digest.md"), "h")

	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger) VALUES (?, 'manual')`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger) VALUES (?, 'manual')`, id); err == nil {
		t.Error("second queued manual run of one automation accepted; want unique error")
	}
	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger) VALUES (?, 'button')`, id); err != nil {
		t.Errorf("queued button run beside a queued manual run refused: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'manual', 'succeeded')`, id); err != nil {
		t.Errorf("finished manual run beside a queued one refused: %v", err)
	}

	cycle := time.Now().UTC().Format(time.RFC3339)
	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, event_cycle) VALUES (?, 'event', 'succeeded', ?)`, id, cycle); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, event_cycle) VALUES (?, 'event', ?)`, id, cycle); err == nil {
		t.Error("second run of one event cycle accepted; want unique error")
	}
	for i := 0; i < 2; i++ {
		if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'event', 'failed')`, id); err != nil {
			t.Errorf("event run %d without a cycle refused: %v", i, err)
		}
	}
}

func TestAutomationIndex_UpsertChangedApprovalHashNeedsConfirmation(t *testing.T) {
	d := openTestDB(t)
	path := filepath.Join(t.TempDir(), "digest.md")
	id := seedAutomationRow(t, d, "digest", path, "h1")
	if err := d.ConfirmAutomation(id, "h1", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := d.SetAutomationEnabled(id, true, time.Now()); err != nil {
		t.Fatal(err)
	}
	if !mustGetAutomation(t, d, id).Runnable() {
		t.Fatal("confirmed, enabled row is not runnable")
	}
	seedAutomationRow(t, d, "digest", path, "h2")
	a := mustGetAutomation(t, d, id)
	if a.ConfirmedHash != "h1" || a.ApprovalHash != "h2" {
		t.Errorf("after an edit: confirmed=%q approval=%q, want h1/h2", a.ConfirmedHash, a.ApprovalHash)
	}
	if a.Runnable() {
		t.Error("row with a changed approval hash is still runnable")
	}
	if list, err := d.ListAutomations(AutomationFilter{RunnableOnly: true}); err != nil || len(list) != 0 {
		t.Errorf("RunnableOnly after an edit = %+v, %v; want none", list, err)
	}
}

func TestAutomationIndex_UpsertRefusesEmptySlugOrPath(t *testing.T) {
	d := openTestDB(t)
	for _, a := range []Automation{
		{Slug: "", Scope: "personal", Path: filepath.Join(t.TempDir(), "x.md")},
		{Slug: "x", Scope: "personal", Path: ""},
	} {
		if _, err := d.UpsertAutomationIndex(a); err == nil {
			t.Errorf("UpsertAutomationIndex(slug %q, path %q) accepted", a.Slug, a.Path)
		}
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM automations`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("%d rows written by refused upserts, want 0", n)
	}
}

func TestAutomationIndex_ListEmptyIsNonNil(t *testing.T) {
	d := openTestDB(t)
	list, err := d.ListAutomations(AutomationFilter{})
	if err != nil {
		t.Fatal(err)
	}
	if list == nil || len(list) != 0 {
		t.Errorf("ListAutomations on an empty index = %#v, want a non-nil empty slice", list)
	}
}

func TestAutomationIndex_ConfirmSetsLastScheduledForNow(t *testing.T) {
	d := openTestDB(t)
	path := filepath.Join(t.TempDir(), "digest.md")
	id := seedAutomationRow(t, d, "digest", path, "h1")
	base := time.Now().Truncate(time.Second)
	old := base.Add(-48 * time.Hour)
	if err := d.SetAutomationEnabled(id, true, old); err != nil {
		t.Fatal(err)
	}
	lastIs := func(label string, want time.Time) {
		t.Helper()
		if a := mustGetAutomation(t, d, id); a.LastScheduledFor == nil || !a.LastScheduledFor.Equal(want) {
			t.Errorf("%s: last_scheduled_for = %v, want %v", label, a.LastScheduledFor, want)
		}
	}

	if err := d.ConfirmAutomation(id, "h1", base); err != nil {
		t.Fatal(err)
	}
	lastIs("first confirm", base)

	// Confirming the already confirmed hash keeps the schedule point.
	if err := d.SetAutomationSchedule(id, &old, nil); err != nil {
		t.Fatal(err)
	}
	if err := d.ConfirmAutomation(id, "h1", base.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	lastIs("re-confirm", old)

	// A refused confirm moves nothing.
	if err := d.ConfirmAutomation(id, "h2", base.Add(2*time.Hour)); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("ConfirmAutomation(h2) before the edit = %v, want ErrHashMismatch", err)
	}
	lastIs("refused confirm", old)

	// Confirming an edited recipe's new hash moves it to now.
	seedAutomationRow(t, d, "digest", path, "h2")
	later := base.Add(3 * time.Hour)
	if err := d.ConfirmAutomation(id, "h2", later); err != nil {
		t.Fatal(err)
	}
	lastIs("confirm after edit", later)
}
