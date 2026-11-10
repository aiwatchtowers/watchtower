package db

import (
	"database/sql"
	"testing"
)

func TestTargetsByBranches_NewestWinsAndOtherWorkbenchesIgnored(t *testing.T) {
	d := openTestDB(t)
	pid, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	other, err := d.CreateWorkbench("other", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	add := func(project int64, text, status, branch, created string) int {
		t.Helper()
		tg := makeTarget(text, status, "medium")
		tg.WorkbenchID = sql.NullInt64{Int64: project, Valid: true}
		id, err := d.CreateTarget(tg)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := d.Exec(`UPDATE targets SET branch = ?, created_at = ? WHERE id = ?`, branch, created, id); err != nil {
			t.Fatal(err)
		}
		return int(id)
	}
	older := add(pid, "older", "done", "feature/a", "2026-01-01T00:00:00Z")
	newer := add(pid, "newer", "done", "feature/a", "2026-02-01T00:00:00Z")
	// The same branch on another workbench is never seen, however new.
	add(other, "foreign", "todo", "feature/a", "2026-03-01T00:00:00Z")
	open := add(pid, "open b", "todo", "feature/b", "2026-01-15T00:00:00Z")
	add(other, "foreign c", "todo", "feature/c", "2026-01-15T00:00:00Z")

	// An older writer stored the branch untrimmed: it still matches, keyed trimmed.
	padded := add(pid, "padded", "todo", " feature/d\n", "2026-01-15T00:00:00Z")

	got, err := d.TargetsByBranches(pid, []string{"feature/a", "feature/b", "feature/c", "", "feature/d "})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d targets: %+v", len(got), got)
	}
	if got["feature/a"].ID != newer {
		t.Fatalf("feature/a = %d, want newest %d (older %d)", got["feature/a"].ID, newer, older)
	}
	if got["feature/b"].ID != open || got["feature/b"].Branch != "feature/b" {
		t.Fatalf("feature/b = %+v", got["feature/b"])
	}
	if got["feature/d"].ID != padded {
		t.Fatalf("feature/d = %+v, want the untrimmed row %d", got["feature/d"], padded)
	}
	if got, err := d.TargetsByBranches(pid, nil); err != nil || len(got) != 0 {
		t.Fatalf("no branches = %+v %v", got, err)
	}
}
