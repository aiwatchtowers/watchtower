package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

// TestMigration00053_SchemaShape covers the schema half on a fully-migrated
// DB: the new read-marker columns exist and are nullable (no row seeded
// through 00053 yet, so nothing to assert about the status flip here).
func TestMigration00053_SchemaShape(t *testing.T) {
	database := OpenTestDB(t)

	for _, col := range []string{"seen_at"} {
		var count int
		if err := database.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('ideas') WHERE name = ?`, col).Scan(&count); err != nil || count != 1 {
			t.Fatalf("ideas.%s missing (count=%d err=%v)", col, count, err)
		}
	}
	for _, col := range []string{"read_at"} {
		var count int
		if err := database.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('stream_digests') WHERE name = ?`, col).Scan(&count); err != nil || count != 1 {
			t.Fatalf("stream_digests.%s missing (count=%d err=%v)", col, count, err)
		}
	}

	// Both columns are nullable and default to NULL (unread / unseen).
	if _, err := database.Exec(`INSERT INTO ideas (kind, title, essence, status, source) VALUES ('idea', 'I', 'i', 'proposed', 'mined')`); err != nil {
		t.Fatalf("insert idea: %v", err)
	}
	var seenAt sql.NullString
	if err := database.QueryRow(`SELECT seen_at FROM ideas WHERE kind = 'idea'`).Scan(&seenAt); err != nil {
		t.Fatalf("read seen_at: %v", err)
	}
	if seenAt.Valid {
		t.Fatalf("seen_at should default to NULL, got %q", seenAt.String)
	}
}

// TestMigration00053_FlipsProposedDecisionsToActive replays goose up to
// 00052 on a raw connection, seeds the pre-00053 shape (a proposed decision
// and a proposed idea), then applies 00053 and asserts the in-place data
// migration: the decision flips to 'active' with a refreshed updated_at,
// the idea is untouched, and the new columns exist.
func TestMigration00053_FlipsProposedDecisionsToActive(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 52); err != nil {
		t.Fatalf("migrate to v52: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO ideas (kind, title, essence, status, source, updated_at) VALUES
		('decision', 'D', 'd', 'proposed', 'mined', '2026-01-01T00:00:00Z'),
		('idea', 'I', 'i', 'proposed', 'mined', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatalf("seed pre-migration ideas: %v", err)
	}
	// A decision already in a terminal status must not be disturbed by the
	// blanket flip (WHERE clause scopes to status='proposed' only).
	if _, err := raw.Exec(`INSERT INTO ideas (kind, title, essence, status, source, updated_at) VALUES
		('decision', 'D2', 'd2', 'rejected', 'mined', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatalf("seed rejected decision: %v", err)
	}

	if err := goose.UpByOne(raw, "migrations"); err != nil {
		t.Fatalf("apply 00053: %v", err)
	}

	var decisionStatus, decisionUpdatedAt string
	if err := raw.QueryRow(`SELECT status, updated_at FROM ideas WHERE kind = 'decision' AND title = 'D'`).
		Scan(&decisionStatus, &decisionUpdatedAt); err != nil {
		t.Fatalf("read flipped decision: %v", err)
	}
	if decisionStatus != "active" {
		t.Errorf("proposed decision status after migration = %q, want active", decisionStatus)
	}
	if decisionUpdatedAt == "2026-01-01T00:00:00Z" {
		t.Errorf("updated_at was not refreshed by the flip")
	}

	var ideaStatus string
	if err := raw.QueryRow(`SELECT status FROM ideas WHERE kind = 'idea'`).Scan(&ideaStatus); err != nil {
		t.Fatalf("read idea: %v", err)
	}
	if ideaStatus != "proposed" {
		t.Errorf("idea status after migration = %q, want proposed (untouched)", ideaStatus)
	}

	var rejectedStatus string
	if err := raw.QueryRow(`SELECT status FROM ideas WHERE kind = 'decision' AND title = 'D2'`).Scan(&rejectedStatus); err != nil {
		t.Fatalf("read rejected decision: %v", err)
	}
	if rejectedStatus != "rejected" {
		t.Errorf("already-terminal decision status after migration = %q, want rejected (untouched)", rejectedStatus)
	}

	// New columns present and nullable post-migration.
	if _, err := raw.Exec(`SELECT seen_at FROM ideas LIMIT 1`); err != nil {
		t.Fatalf("ideas.seen_at missing: %v", err)
	}
	if _, err := raw.Exec(`SELECT read_at FROM stream_digests LIMIT 1`); err != nil {
		t.Fatalf("stream_digests.read_at missing: %v", err)
	}
}

// TestMigration00053DownDropsMarkerColumns: Down removes the two read-marker
// columns but deliberately does not (cannot) revert the status flip.
func TestMigration00053DownDropsMarkerColumns(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.Up(raw, "migrations"); err != nil {
		t.Fatalf("migrate up: %v", err)
	}

	if err := goose.DownTo(raw, "migrations", 52); err != nil {
		t.Fatalf("goose down to 52: %v", err)
	}

	if _, err := raw.Exec(`SELECT seen_at FROM ideas LIMIT 1`); err == nil {
		t.Fatal("ideas.seen_at should be dropped after down")
	}
	if _, err := raw.Exec(`SELECT read_at FROM stream_digests LIMIT 1`); err == nil {
		t.Fatal("stream_digests.read_at should be dropped after down")
	}
}
