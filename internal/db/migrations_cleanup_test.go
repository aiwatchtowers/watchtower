package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

// Drives goose to v5 (observers table exists, before cleanup), seeds a
// default-looking observer + a custom one with events, then applies 00006 and
// asserts only the default observer (and its events) was removed.
func TestMigration00006DropsDefaultObservers(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}

	if err := goose.UpTo(raw, "migrations", 5); err != nil {
		t.Fatalf("migrate to v5: %v", err)
	}

	const defName = "Activity watcher"
	const defInstr = "Track anything across all sources that affects the progress, status, blockers, or decisions of this goal. Surface relevant updates and flag when the status or next step should change."

	res, err := raw.Exec(`INSERT INTO observers (entity_type, entity_id, name, instruction, enabled)
		VALUES ('target', 1, ?, ?, 1)`, defName, defInstr)
	if err != nil {
		t.Fatal(err)
	}
	defID, _ := res.LastInsertId()
	if _, err := raw.Exec(`INSERT INTO observer_events (observer_id, entity_type, entity_id, summary)
		VALUES (?, 'target', 1, 'stale auto event')`, defID); err != nil {
		t.Fatal(err)
	}

	res, err = raw.Exec(`INSERT INTO observers (entity_type, entity_id, name, instruction, enabled)
		VALUES ('target', 1, 'Custom watcher', 'Watch only the billing refund decision.', 1)`)
	if err != nil {
		t.Fatal(err)
	}
	customID, _ := res.LastInsertId()
	if _, err := raw.Exec(`INSERT INTO observer_events (observer_id, entity_type, entity_id, summary)
		VALUES (?, 'target', 1, 'real event')`, customID); err != nil {
		t.Fatal(err)
	}

	if err := goose.Up(raw, "migrations"); err != nil {
		t.Fatalf("apply 00006: %v", err)
	}

	var obsCount int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM observers`).Scan(&obsCount); err != nil {
		t.Fatal(err)
	}
	if obsCount != 1 {
		t.Fatalf("expected only the custom observer to remain, got %d", obsCount)
	}
	var remainingID int64
	if err := raw.QueryRow(`SELECT id FROM observers`).Scan(&remainingID); err != nil {
		t.Fatal(err)
	}
	if remainingID != customID {
		t.Fatalf("wrong observer survived: got id %d, want %d", remainingID, customID)
	}
	var evtCount int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM observer_events`).Scan(&evtCount); err != nil {
		t.Fatal(err)
	}
	if evtCount != 1 {
		t.Fatalf("default observer's events must cascade-delete; got %d events", evtCount)
	}
}
