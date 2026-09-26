package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

// NOTE: TestMigration00006DropsDefaultObservers was removed with migration
// 00008 (custom tracks): it drove goose.Up to HEAD, which now drops the
// observers/observer_events tables entirely, so asserting which observer rows
// survive 00006 is no longer meaningful.

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
