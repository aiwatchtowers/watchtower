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

// Drives goose to v6 (before the external_ref cleanup), seeds target_links
// rows in the malformed "slack:<url>" format alongside healthy ones, then
// applies 00007 and asserts: refs are blanked where the row can keep its
// target link, rows that would violate the CHECK (no target) or the UNIQUE
// index (clean duplicate exists) are deleted, and healthy refs are untouched.
func TestMigration00007CleansMalformedExternalRefs(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 6); err != nil {
		t.Fatalf("migrate to v6: %v", err)
	}

	for i := 0; i < 2; i++ {
		if _, err := raw.Exec(`INSERT INTO targets (text, period_start, period_end)
			VALUES ('t', '2026-07-01', '2026-07-31')`); err != nil {
			t.Fatal(err)
		}
	}
	seed := func(target any, ref, relation string) {
		t.Helper()
		if _, err := raw.Exec(`INSERT INTO target_links
			(source_target_id, target_target_id, external_ref, relation, created_by)
			VALUES (1, ?, ?, ?, 'ai')`, target, ref, relation); err != nil {
			t.Fatal(err)
		}
	}
	seed(nil, "slack:https://x.slack.com/archives/C1/p1", "related")  // no target → delete
	seed(2, "slack:https://x.slack.com/archives/C1/p2", "blocks")     // has target → blank
	seed(2, "", "related")                                            // clean duplicate…
	seed(2, "slack:https://x.slack.com/archives/C1/p3", "related")    // …malformed twin → delete
	seed(nil, "jira:ABC-1", "related")                                // healthy ref → untouched
	seed(2, "slack:https://x.slack.com/archives/C1/p4", "duplicates") // colliding malformed twins with…
	seed(2, "slack:https://x.slack.com/archives/C1/p5", "duplicates") // …no clean dup → keep exactly one, blanked

	if err := goose.Up(raw, "migrations"); err != nil {
		t.Fatalf("apply 00007: %v", err)
	}

	var malformed int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM target_links
		WHERE external_ref LIKE 'slack:http%'`).Scan(&malformed); err != nil {
		t.Fatal(err)
	}
	if malformed != 0 {
		t.Fatalf("expected 0 malformed refs after cleanup, got %d", malformed)
	}
	var total int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM target_links`).Scan(&total); err != nil {
		t.Fatal(err)
	}
	if total != 4 {
		t.Fatalf("expected 4 surviving links (blanked + clean dup + jira + one blanked collision twin), got %d", total)
	}
	var blanked int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM target_links
		WHERE target_target_id = 2 AND relation = 'blocks' AND external_ref = ''`).Scan(&blanked); err != nil {
		t.Fatal(err)
	}
	if blanked != 1 {
		t.Fatalf("row with a target link should have its ref blanked, got %d", blanked)
	}
	var jira int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM target_links
		WHERE external_ref = 'jira:ABC-1'`).Scan(&jira); err != nil {
		t.Fatal(err)
	}
	if jira != 1 {
		t.Fatalf("healthy external ref must be untouched, got %d", jira)
	}
	// The colliding malformed twins (same source/target/relation, different
	// URLs, no clean '' twin) must not both survive the DELETE: blanking both
	// would violate UNIQUE(source_target_id, target_target_id, external_ref,
	// relation) and abort the whole migration.
	var collided int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM target_links
		WHERE target_target_id = 2 AND relation = 'duplicates' AND external_ref = ''`).Scan(&collided); err != nil {
		t.Fatal(err)
	}
	if collided != 1 {
		t.Fatalf("exactly one blanked collision twin must survive, got %d", collided)
	}
}
