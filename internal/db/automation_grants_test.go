package db

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

// seedGrantRun inserts a running run of automation id claimed with recipeHash.
func seedGrantRun(t *testing.T, d *DB, automationID int64, recipeHash string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, recipe_hash)
		VALUES (?, 'manual', 'running', ?)`, automationID, recipeHash)
	if err != nil {
		t.Fatalf("seeding a run of automation %d: %v", automationID, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func setApprovalHash(t *testing.T, d *DB, id int64, hash string) {
	t.Helper()
	if _, err := d.Exec(`UPDATE automations SET approval_hash = ? WHERE id = ?`, hash, id); err != nil {
		t.Fatalf("setting approval_hash of %d: %v", id, err)
	}
}

func mustSetGrant(t *testing.T, d *DB, id int64, tool, hash string) {
	t.Helper()
	if err := d.SetAutomationToolGrant(id, tool, hash, time.Now()); err != nil {
		t.Fatalf("SetAutomationToolGrant(%d, %s, %s): %v", id, tool, hash, err)
	}
}

func countGrants(t *testing.T, d *DB, id int64) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM automation_tool_grants WHERE automation_id = ?`, id).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestMigration00115_GrantsTable(t *testing.T) {
	d := openTestDB(t)
	var name string
	if err := d.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'automation_tool_grants'`).Scan(&name); err != nil {
		t.Fatalf("automation_tool_grants missing after migration: %v", err)
	}
	id := seedAutomationRow(t, d, "digest", filepath.Join(t.TempDir(), "digest.md"), "h1")
	if _, err := d.Exec(`INSERT INTO automation_tool_grants (automation_id, tool, grant_hash) VALUES (?, 'create_target', 'h1')`, id); err != nil {
		t.Fatalf("insert grant: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO automation_tool_grants (automation_id, tool, grant_hash) VALUES (?, 'create_target', 'h2')`, id); err == nil {
		t.Error("second grant for the same (automation, tool) inserted; want PRIMARY KEY error")
	}
	var grantedAt string
	if err := d.QueryRow(`SELECT granted_at FROM automation_tool_grants WHERE automation_id = ?`, id).Scan(&grantedAt); err != nil {
		t.Fatal(err)
	}
	if _, err := time.Parse(automationTimeLayout, grantedAt); err != nil {
		t.Errorf("granted_at default %q is not RFC 3339 seconds: %v", grantedAt, err)
	}
	if _, err := d.Exec(`DELETE FROM automations WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	if n := countGrants(t, d, id); n != 0 {
		t.Errorf("grants after deleting the automation = %d, want 0 (ON DELETE CASCADE)", n)
	}
}

func TestGrant_SetRefusesStaleHash(t *testing.T) {
	d := openTestDB(t)
	id := seedAutomationRow(t, d, "digest", filepath.Join(t.TempDir(), "digest.md"), "h1")
	for _, hash := range []string{"other", ""} {
		err := d.SetAutomationToolGrant(id, "create_target", hash, time.Now())
		if !errors.Is(err, ErrHashMismatch) {
			t.Errorf("SetAutomationToolGrant(hash %q) = %v, want ErrHashMismatch", hash, err)
		}
	}
	if n := countGrants(t, d, id); n != 0 {
		t.Errorf("grants after refused sets = %d, want 0", n)
	}
	if err := d.SetAutomationToolGrant(id+100, "create_target", "h1", time.Now()); !errors.Is(err, ErrAutomationNotFound) {
		t.Errorf("SetAutomationToolGrant(missing automation) = %v, want ErrAutomationNotFound", err)
	}
}

func TestGrant_ActiveRequiresAllThreeHashes(t *testing.T) {
	cases := []struct {
		name string
		// setup returns the run id and the tool to ask about.
		setup func(t *testing.T, d *DB, a, b int64) (int64, string)
		want  bool
	}{
		{"grant = approval = run", func(t *testing.T, d *DB, a, _ int64) (int64, string) {
			return seedGrantRun(t, d, a, "h1"), "create_target"
		}, true},
		{"run claimed with an older recipe_hash", func(t *testing.T, d *DB, a, _ int64) (int64, string) {
			return seedGrantRun(t, d, a, "h0"), "create_target"
		}, false},
		{"approval changed by a rescan", func(t *testing.T, d *DB, a, _ int64) (int64, string) {
			run := seedGrantRun(t, d, a, "h1")
			setApprovalHash(t, d, a, "h2")
			return run, "create_target"
		}, false},
		{"another automation's run", func(t *testing.T, d *DB, _, b int64) (int64, string) {
			return seedGrantRun(t, d, b, "h1"), "create_target"
		}, false},
		{"another tool", func(t *testing.T, d *DB, a, _ int64) (int64, string) {
			return seedGrantRun(t, d, a, "h1"), "send_slack_message"
		}, false},
		{"empty approval_hash", func(t *testing.T, d *DB, a, _ int64) (int64, string) {
			if _, err := d.Exec(`UPDATE automation_tool_grants SET grant_hash = '' WHERE automation_id = ?`, a); err != nil {
				t.Fatal(err)
			}
			setApprovalHash(t, d, a, "")
			return seedGrantRun(t, d, a, ""), "create_target"
		}, false},
		{"missing run", func(t *testing.T, _ *DB, _, _ int64) (int64, string) {
			return 9999, "create_target"
		}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := openTestDB(t)
			dir := t.TempDir()
			a := seedAutomationRow(t, d, "digest", filepath.Join(dir, "digest.md"), "h1")
			b := seedAutomationRow(t, d, "other", filepath.Join(dir, "other.md"), "h1")
			mustSetGrant(t, d, a, "create_target", "h1")
			run, tool := tc.setup(t, d, a, b)
			got, err := d.ActiveAutomationToolGrant(run, tool)
			if err != nil {
				t.Fatalf("ActiveAutomationToolGrant: %v", err)
			}
			if got != tc.want {
				t.Errorf("ActiveAutomationToolGrant = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestGrant_ListMarksInactive(t *testing.T) {
	d := openTestDB(t)
	id := seedAutomationRow(t, d, "digest", filepath.Join(t.TempDir(), "digest.md"), "h1")
	now := time.Date(2026, 10, 14, 9, 30, 0, 0, time.UTC)
	if err := d.SetAutomationToolGrant(id, "send_slack_message", "h1", now); err != nil {
		t.Fatal(err)
	}
	if err := d.SetAutomationToolGrant(id, "create_target", "h1", now); err != nil {
		t.Fatal(err)
	}
	wantGrants(t, "before the edit", mustListGrants(t, d, id), []AutomationToolGrant{
		{AutomationID: id, Tool: "create_target", GrantHash: "h1", GrantedAt: now, Active: true},
		{AutomationID: id, Tool: "send_slack_message", GrantHash: "h1", GrantedAt: now, Active: true},
	})

	setApprovalHash(t, d, id, "h2")
	wantGrants(t, "after approval_hash changed", mustListGrants(t, d, id), []AutomationToolGrant{
		{AutomationID: id, Tool: "create_target", GrantHash: "h1", GrantedAt: now},
		{AutomationID: id, Tool: "send_slack_message", GrantHash: "h1", GrantedAt: now},
	})

	later := now.Add(time.Hour)
	if err := d.SetAutomationToolGrant(id, "create_target", "h2", later); err != nil {
		t.Fatal(err)
	}
	wantGrants(t, "after re-granting create_target", mustListGrants(t, d, id), []AutomationToolGrant{
		{AutomationID: id, Tool: "create_target", GrantHash: "h2", GrantedAt: later, Active: true},
		{AutomationID: id, Tool: "send_slack_message", GrantHash: "h1", GrantedAt: now},
	})
}

func wantGrants(t *testing.T, when string, got, want []AutomationToolGrant) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("grants %s = %+v, want %+v", when, got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("grant %d %s = %+v, want %+v", i, when, got[i], want[i])
		}
	}
}

func TestGrant_DeleteAutomationToolGrant(t *testing.T) {
	d := openTestDB(t)
	id := seedAutomationRow(t, d, "digest", filepath.Join(t.TempDir(), "digest.md"), "h1")
	mustSetGrant(t, d, id, "create_target", "h1")
	removed, err := d.DeleteAutomationToolGrant(id, "create_target")
	if err != nil || !removed {
		t.Fatalf("DeleteAutomationToolGrant = (%v, %v), want (true, nil)", removed, err)
	}
	removed, err = d.DeleteAutomationToolGrant(id, "create_target")
	if err != nil || removed {
		t.Errorf("second DeleteAutomationToolGrant = (%v, %v), want (false, nil)", removed, err)
	}
	if got := mustListGrants(t, d, id); len(got) != 0 {
		t.Errorf("grants after delete = %+v, want none", got)
	}
}

func mustListGrants(t *testing.T, d *DB, id int64) []AutomationToolGrant {
	t.Helper()
	got, err := d.ListAutomationToolGrants(id)
	if err != nil {
		t.Fatalf("ListAutomationToolGrants(%d): %v", id, err)
	}
	return got
}
