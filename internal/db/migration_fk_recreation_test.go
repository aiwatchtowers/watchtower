package db

import (
	"database/sql"
	"testing"

	_ "modernc.org/sqlite"
)

// TestMigration_TableRecreationPreservesCascadeChildren guards a real
// incident: migration 00002_target_due_inbox.sql recreates inbox_items via
// the CREATE-new/INSERT-SELECT/DROP/RENAME dance needed to expand a CHECK
// constraint, while inbox_feedback holds `inbox_item_id INTEGER NOT NULL
// REFERENCES inbox_items(id) ON DELETE CASCADE`. With PRAGMA foreign_keys=ON
// (set unconditionally in db.go's setPragmas), DROP TABLE inbox_items
// deletes every row of inbox_items, firing the ON DELETE CASCADE and wiping
// every row of inbox_feedback along with it.
//
// The migration tried to guard against this with `PRAGMA defer_foreign_keys
// = ON`, but that pragma only postpones the *validation* of dangling
// foreign-key references until commit — it does nothing to the ON DELETE
// CASCADE *action*, which fires the moment the parent rows are deleted. The
// second subtest below reproduces that exact antipattern and documents that
// it does NOT save the data (00002 already shipped this bug; it is applied
// and cannot be edited retroactively).
//
// The correct guard, exercised by the first subtest, is `PRAGMA
// foreign_keys = OFF` wrapped around the whole dance, re-enabled once the
// table is back in place. This must be issued as its own statement outside
// any transaction: SQLite refuses to toggle `foreign_keys` while a BEGIN is
// open, which is also why `defer_foreign_keys` (whose entire purpose is to
// work *inside* a transaction) was reached for in the first place.
func TestMigration_TableRecreationPreservesCascadeChildren(t *testing.T) {
	newSeededSchema := func(t *testing.T) *sql.DB {
		t.Helper()
		raw, err := sql.Open("sqlite", ":memory:")
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		t.Cleanup(func() { _ = raw.Close() })
		// Required for :memory: databases: database/sql pools connections,
		// and each new connection to ":memory:" is a distinct empty DB.
		raw.SetMaxOpenConns(1)

		for _, stmt := range []string{
			"PRAGMA foreign_keys=ON",
			`CREATE TABLE inbox_items (
				id         INTEGER PRIMARY KEY AUTOINCREMENT,
				channel_id TEXT NOT NULL
			)`,
			`CREATE TABLE inbox_feedback (
				id            INTEGER PRIMARY KEY AUTOINCREMENT,
				inbox_item_id INTEGER NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
				rating        INTEGER NOT NULL CHECK(rating IN (-1,1))
			)`,
			`INSERT INTO inbox_items (channel_id) VALUES ('C1')`,
			`INSERT INTO inbox_feedback (inbox_item_id, rating) VALUES (1, 1)`,
		} {
			if _, err := raw.Exec(stmt); err != nil {
				t.Fatalf("seed exec %q: %v", stmt, err)
			}
		}
		return raw
	}

	feedbackRows := func(t *testing.T, raw *sql.DB) int {
		t.Helper()
		var n int
		if err := raw.QueryRow(`SELECT COUNT(*) FROM inbox_feedback`).Scan(&n); err != nil {
			t.Fatalf("count inbox_feedback: %v", err)
		}
		return n
	}

	t.Run("foreign_keys=OFF preserves cascade children", func(t *testing.T) {
		raw := newSeededSchema(t)

		for _, stmt := range []string{
			"PRAGMA foreign_keys=OFF",
			`CREATE TABLE inbox_items_new (
				id         INTEGER PRIMARY KEY AUTOINCREMENT,
				channel_id TEXT NOT NULL
			)`,
			`INSERT INTO inbox_items_new SELECT * FROM inbox_items`,
			`DROP TABLE inbox_items`,
			`ALTER TABLE inbox_items_new RENAME TO inbox_items`,
			"PRAGMA foreign_keys=ON",
		} {
			if _, err := raw.Exec(stmt); err != nil {
				t.Fatalf("exec %q: %v", stmt, err)
			}
		}

		if got := feedbackRows(t, raw); got != 1 {
			t.Fatalf("inbox_feedback should survive table recreation under foreign_keys=OFF, got %d rows, want 1", got)
		}
	})

	t.Run("defer_foreign_keys=ON does NOT save cascade children (antipattern, matches migration 00002's bug)", func(t *testing.T) {
		raw := newSeededSchema(t)

		// This is the pattern migration 00002_target_due_inbox.sql actually
		// used. It looks safe -- "defer the FK checks" -- but DROP TABLE
		// still cascades into inbox_feedback immediately; deferring only
		// postpones SQLite's re-validation that no dangling reference is
		// left at commit, which is a no-op here since the rename recreates
		// a same-named table before commit anyway.
		for _, stmt := range []string{
			"PRAGMA defer_foreign_keys=ON",
			`CREATE TABLE inbox_items_new (
				id         INTEGER PRIMARY KEY AUTOINCREMENT,
				channel_id TEXT NOT NULL
			)`,
			`INSERT INTO inbox_items_new SELECT * FROM inbox_items`,
			`DROP TABLE inbox_items`,
			`ALTER TABLE inbox_items_new RENAME TO inbox_items`,
		} {
			if _, err := raw.Exec(stmt); err != nil {
				t.Fatalf("exec %q: %v", stmt, err)
			}
		}

		if got := feedbackRows(t, raw); got != 0 {
			t.Fatalf("antipattern demonstration expected the cascade to wipe inbox_feedback (0 rows), got %d -- "+
				"if this now passes with rows preserved, modernc.org/sqlite's defer_foreign_keys semantics changed "+
				"and the warning in .claude/skills/add-migration/SKILL.md needs revisiting", got)
		}
	})
}
