package db

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

// RunSchemaUpgrade is the one-shot transition from the legacy migration
// engine (PRAGMA user_version + manual switch in migrate()) to goose.
//
// It opens dbPath directly (no schema-version checks during Open) and:
//
//   - returns nil if PRAGMA user_version == 0 and no goose table (fresh DB)
//   - if goose_db_version exists but baseline tables are missing, backfills
//     them (repairs partially-migrated databases)
//   - if goose_db_version doesn't exist and user_version > 0, runs full
//     baseline backfill and creates goose tracking table
//
// PRAGMA user_version is preserved on the legacy value: the Swift Desktop
// app uses it as a "is the schema usable" guard (requires >= 3) and
// resetting it would lock the Desktop out of an otherwise-fine database.
//
// Caller is responsible for invoking this once per startup before any
// db.Open() call when config.DB.SchemaFormat < CurrentSchemaFormat.
func RunSchemaUpgrade(dbPath string) error {
	raw, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return fmt.Errorf("opening db for schema upgrade: %w", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)

	var hasGoose int
	if err := raw.QueryRow(
		`SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='goose_db_version')`,
	).Scan(&hasGoose); err != nil {
		return fmt.Errorf("checking goose_db_version: %w", err)
	}

	if hasGoose == 1 {
		// Goose already set up. Check if baseline tables are missing
		// (e.g. tables added to 00001_init.sql after the legacy freeze).
		if needsBackfill(raw) {
			tx, err := raw.Begin()
			if err != nil {
				return fmt.Errorf("beginning backfill tx: %w", err)
			}
			defer tx.Rollback()
			if err := runBaselineBackfill(tx); err != nil {
				return fmt.Errorf("backfilling baseline tables: %w", err)
			}
			return tx.Commit()
		}
		return nil
	}

	var userVersion int
	if err := raw.QueryRow(`PRAGMA user_version`).Scan(&userVersion); err != nil {
		return fmt.Errorf("reading user_version: %w", err)
	}
	if userVersion == 0 {
		return nil
	}

	tx, err := raw.Begin()
	if err != nil {
		return fmt.Errorf("beginning transition tx: %w", err)
	}
	defer tx.Rollback()

	// Run full baseline so that any tables added to the squashed init
	// after the legacy schema was frozen are created. Every statement
	// uses CREATE TABLE/INDEX IF NOT EXISTS, so existing objects are
	// left untouched.
	if err := runBaselineBackfill(tx); err != nil {
		return fmt.Errorf("backfilling baseline tables: %w", err)
	}

	if _, err := tx.Exec(`CREATE TABLE goose_db_version (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		version_id  INTEGER NOT NULL,
		is_applied  INTEGER NOT NULL,
		tstamp      TIMESTAMP DEFAULT (datetime('now'))
	)`); err != nil {
		return fmt.Errorf("creating goose_db_version: %w", err)
	}
	if _, err := tx.Exec(`INSERT INTO goose_db_version (version_id, is_applied) VALUES (0, 1)`); err != nil {
		return fmt.Errorf("seeding goose_db_version baseline: %w", err)
	}
	if _, err := tx.Exec(`INSERT INTO goose_db_version (version_id, is_applied) VALUES (1, 1)`); err != nil {
		return fmt.Errorf("marking baseline applied: %w", err)
	}
	// Note: PRAGMA user_version is NOT reset — Swift Desktop uses it as a
	// schema-version sanity check (requires >= 3) and zeroing it locks
	// the desktop out. Goose tracks state in goose_db_version instead.
	return tx.Commit()
}

// needsBackfill returns true if any baseline table from 00001_init.sql is
// missing or if inbox_items is missing columns added in the squashed baseline.
func needsBackfill(db *sql.DB) bool {
	tables := []string{"targets", "track_states", "day_plans", "jira_releases", "meeting_notes"}
	for _, t := range tables {
		var exists int
		if err := db.QueryRow(
			`SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)`, t,
		).Scan(&exists); err != nil || exists == 0 {
			return true
		}
	}
	// Also check that inbox_items has the columns expected by 00002.
	var colCount int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('inbox_items')`,
	).Scan(&colCount); err == nil && colCount < 24 {
		return true
	}
	return false
}

// runBaselineBackfill executes CREATE TABLE/INDEX IF NOT EXISTS for every
// table in the 00001_init.sql baseline that may be missing from legacy
// databases. It also upgrades existing tables (e.g. inbox_items) to match
// the baseline schema so that subsequent goose migrations can operate on
// them without column-count mismatches.
func runBaselineBackfill(tx *sql.Tx) error {
	// Upgrade inbox_items to match 00001 baseline (add missing columns).
	// Each ALTER is guarded — if the column already exists, the error is
	// silently ignored.
	if err := upgradeInboxItems(tx); err != nil {
		return fmt.Errorf("upgrading inbox_items: %w", err)
	}

	stmts := []string{
		// track_states
		`CREATE TABLE IF NOT EXISTS track_states (
			id                 INTEGER PRIMARY KEY AUTOINCREMENT,
			track_id           INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
			text               TEXT NOT NULL,
			context            TEXT NOT NULL DEFAULT '',
			category           TEXT NOT NULL,
			ownership          TEXT NOT NULL,
			ball_on            TEXT NOT NULL DEFAULT '',
			owner_user_id      TEXT NOT NULL DEFAULT '',
			requester_name     TEXT NOT NULL DEFAULT '',
			requester_user_id  TEXT NOT NULL DEFAULT '',
			blocking           TEXT NOT NULL DEFAULT '',
			decision_summary   TEXT NOT NULL DEFAULT '',
			decision_options   TEXT NOT NULL DEFAULT '[]',
			sub_items          TEXT NOT NULL DEFAULT '[]',
			participants       TEXT NOT NULL DEFAULT '[]',
			tags               TEXT NOT NULL DEFAULT '[]',
			priority           TEXT NOT NULL,
			due_date           REAL,
			source             TEXT NOT NULL CHECK(source IN ('extraction','manual')),
			model              TEXT NOT NULL DEFAULT '',
			prompt_version     INTEGER NOT NULL DEFAULT 0,
			created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`CREATE INDEX IF NOT EXISTS idx_track_states_track ON track_states(track_id, created_at DESC)`,

		// targets
		`CREATE TABLE IF NOT EXISTS targets (
			id                  INTEGER PRIMARY KEY AUTOINCREMENT,
			text                TEXT NOT NULL,
			intent              TEXT NOT NULL DEFAULT '',
			level               TEXT NOT NULL DEFAULT 'day'
			                    CHECK(level IN ('quarter','month','week','day','custom')),
			custom_label        TEXT NOT NULL DEFAULT '',
			period_start        TEXT NOT NULL,
			period_end          TEXT NOT NULL,
			parent_id           INTEGER REFERENCES targets(id) ON DELETE SET NULL,
			status              TEXT NOT NULL DEFAULT 'todo'
			                    CHECK(status IN ('todo','in_progress','blocked','done','dismissed','snoozed')),
			priority            TEXT NOT NULL DEFAULT 'medium'
			                    CHECK(priority IN ('high','medium','low')),
			ownership           TEXT NOT NULL DEFAULT 'mine'
			                    CHECK(ownership IN ('mine','delegated','watching')),
			ball_on             TEXT NOT NULL DEFAULT '',
			due_date            TEXT NOT NULL DEFAULT '',
			snooze_until        TEXT NOT NULL DEFAULT '',
			blocking            TEXT NOT NULL DEFAULT '',
			tags                TEXT NOT NULL DEFAULT '[]',
			sub_items           TEXT NOT NULL DEFAULT '[]',
			notes               TEXT NOT NULL DEFAULT '[]',
			progress            REAL NOT NULL DEFAULT 0.0,
			source_type         TEXT NOT NULL DEFAULT 'manual'
			                    CHECK(source_type IN ('extract','track','digest','briefing','manual','chat','inbox','jira','slack','promoted_subitem')),
			source_id           TEXT NOT NULL DEFAULT '',
			ai_level_confidence REAL DEFAULT NULL,
			created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
			updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
		)`,
		`CREATE INDEX IF NOT EXISTS idx_targets_level       ON targets(level)`,
		`CREATE INDEX IF NOT EXISTS idx_targets_parent      ON targets(parent_id)`,
		`CREATE INDEX IF NOT EXISTS idx_targets_period      ON targets(period_start, period_end)`,
		`CREATE INDEX IF NOT EXISTS idx_targets_status      ON targets(status)`,
		`CREATE INDEX IF NOT EXISTS idx_targets_priority    ON targets(priority)`,
		`CREATE INDEX IF NOT EXISTS idx_targets_due         ON targets(due_date)`,
		`CREATE INDEX IF NOT EXISTS idx_targets_source      ON targets(source_type, source_id)`,
		`CREATE INDEX IF NOT EXISTS idx_targets_updated     ON targets(updated_at DESC)`,

		// target_links
		`CREATE TABLE IF NOT EXISTS target_links (
			id               INTEGER PRIMARY KEY AUTOINCREMENT,
			source_target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
			target_target_id INTEGER REFERENCES targets(id) ON DELETE CASCADE,
			external_ref     TEXT NOT NULL DEFAULT '',
			relation         TEXT NOT NULL
			                 CHECK(relation IN ('contributes_to','blocks','related','duplicates')),
			confidence       REAL DEFAULT NULL,
			created_by       TEXT NOT NULL DEFAULT 'ai'
			                 CHECK(created_by IN ('ai','user')),
			created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
			CHECK (target_target_id IS NOT NULL OR external_ref != ''),
			UNIQUE(source_target_id, target_target_id, external_ref, relation)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_target_links_source   ON target_links(source_target_id)`,
		`CREATE INDEX IF NOT EXISTS idx_target_links_target   ON target_links(target_target_id)`,
		`CREATE INDEX IF NOT EXISTS idx_target_links_external ON target_links(external_ref)`,

		// inbox_learned_rules
		`CREATE TABLE IF NOT EXISTS inbox_learned_rules (
			id             INTEGER PRIMARY KEY AUTOINCREMENT,
			rule_type      TEXT NOT NULL CHECK(rule_type IN ('source_mute','source_boost','trigger_downgrade','trigger_boost')),
			scope_key      TEXT NOT NULL,
			weight         REAL NOT NULL,
			source         TEXT NOT NULL CHECK(source IN ('implicit','explicit_feedback','user_rule')),
			evidence_count INTEGER NOT NULL DEFAULT 0,
			last_updated   TEXT NOT NULL,
			UNIQUE(rule_type, scope_key)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_inbox_learned_rules_scope ON inbox_learned_rules(rule_type, scope_key)`,

		// inbox_feedback
		`CREATE TABLE IF NOT EXISTS inbox_feedback (
			id            INTEGER PRIMARY KEY AUTOINCREMENT,
			inbox_item_id INTEGER NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
			rating        INTEGER NOT NULL CHECK(rating IN (-1,1)),
			reason        TEXT DEFAULT '' CHECK(reason IN ('','source_noise','wrong_priority','wrong_class','never_show')),
			created_at    TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_inbox_feedback_item ON inbox_feedback(inbox_item_id)`,

		// meeting_notes
		`CREATE TABLE IF NOT EXISTS meeting_notes (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			event_id TEXT NOT NULL,
			type TEXT NOT NULL CHECK(type IN ('question', 'note')),
			text TEXT NOT NULL DEFAULT '',
			is_checked INTEGER NOT NULL DEFAULT 0,
			sort_order INTEGER NOT NULL DEFAULT 0,
			task_id INTEGER,
			created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`CREATE INDEX IF NOT EXISTS idx_meeting_notes_event ON meeting_notes(event_id)`,

		// meeting_recaps
		`CREATE TABLE IF NOT EXISTS meeting_recaps (
			event_id    TEXT PRIMARY KEY REFERENCES calendar_events(id) ON DELETE CASCADE,
			source_text TEXT NOT NULL,
			recap_json  TEXT NOT NULL,
			created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,

		// calendar_auth_state
		`CREATE TABLE IF NOT EXISTS calendar_auth_state (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			status TEXT NOT NULL DEFAULT 'ok',
			error TEXT NOT NULL DEFAULT '',
			updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`INSERT OR IGNORE INTO calendar_auth_state (id, status, error) VALUES (1, 'ok', '')`,

		// jira_custom_fields
		`CREATE TABLE IF NOT EXISTS jira_custom_fields (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			field_type TEXT NOT NULL,
			items_type TEXT NOT NULL DEFAULT '',
			is_useful INTEGER NOT NULL DEFAULT 0,
			usage_hint TEXT NOT NULL DEFAULT '',
			synced_at TEXT NOT NULL DEFAULT ''
		)`,

		// jira_board_field_map
		`CREATE TABLE IF NOT EXISTS jira_board_field_map (
			board_id INTEGER NOT NULL,
			field_id TEXT NOT NULL,
			role TEXT NOT NULL,
			PRIMARY KEY (board_id, field_id)
		)`,

		// jira_releases
		`CREATE TABLE IF NOT EXISTS jira_releases (
			id INTEGER NOT NULL,
			project_key TEXT NOT NULL,
			name TEXT NOT NULL,
			description TEXT NOT NULL DEFAULT '',
			release_date TEXT NOT NULL DEFAULT '',
			released INTEGER NOT NULL DEFAULT 0,
			archived INTEGER NOT NULL DEFAULT 0,
			synced_at TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (id),
			UNIQUE(project_key, name)
		)`,

		// day_plans
		`CREATE TABLE IF NOT EXISTS day_plans (
			id                   INTEGER PRIMARY KEY AUTOINCREMENT,
			user_id              TEXT NOT NULL,
			plan_date            TEXT NOT NULL,
			status               TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
			has_conflicts        INTEGER NOT NULL DEFAULT 0,
			conflict_summary     TEXT,
			generated_at         TEXT NOT NULL,
			last_regenerated_at  TEXT,
			regenerate_count     INTEGER NOT NULL DEFAULT 0,
			feedback_history     TEXT,
			prompt_version       TEXT,
			briefing_id          INTEGER,
			read_at              TEXT,
			created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
			updated_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
			UNIQUE (user_id, plan_date),
			FOREIGN KEY (briefing_id) REFERENCES briefings(id) ON DELETE SET NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_day_plans_date ON day_plans(plan_date DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_day_plans_user_date ON day_plans(user_id, plan_date DESC)`,

		// day_plan_items
		`CREATE TABLE IF NOT EXISTS day_plan_items (
			id           INTEGER PRIMARY KEY AUTOINCREMENT,
			day_plan_id  INTEGER NOT NULL,
			kind         TEXT NOT NULL CHECK (kind IN ('timeblock','backlog')),
			source_type  TEXT NOT NULL CHECK (source_type IN ('task','briefing_attention','jira','calendar','manual','focus')),
			source_id    TEXT,
			title        TEXT NOT NULL,
			description  TEXT,
			rationale    TEXT,
			start_time   TEXT,
			end_time     TEXT,
			duration_min INTEGER,
			priority     TEXT CHECK (priority IS NULL OR priority IN ('high','medium','low')),
			status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','skipped')),
			order_index  INTEGER NOT NULL DEFAULT 0,
			tags         TEXT,
			created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
			updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
			FOREIGN KEY (day_plan_id) REFERENCES day_plans(id) ON DELETE CASCADE
		)`,
		`CREATE INDEX IF NOT EXISTS idx_day_plan_items_plan ON day_plan_items(day_plan_id)`,
		`CREATE INDEX IF NOT EXISTS idx_day_plan_items_source ON day_plan_items(source_type, source_id)`,
	}

	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("executing backfill: %w\nSQL: %.200s", err, stmt)
		}
	}
	return nil
}

// hasColumn checks whether a table has a specific column.
func hasColumnUpgrade(tx *sql.Tx, table, column string) bool {
	rows, err := tx.Query(fmt.Sprintf("PRAGMA table_info(%s)", table))
	if err != nil {
		return false
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull int
		var dflt sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			continue
		}
		if name == column {
			return true
		}
	}
	return false
}

// upgradeInboxItems brings a legacy inbox_items table up to the 00001
// baseline schema by adding missing columns and renaming task_id → target_id.
// This is necessary so that 00002's INSERT INTO inbox_items_new SELECT *
// produces the correct number of columns.
func upgradeInboxItems(tx *sql.Tx) error {
	// Check if the table exists at all
	var exists int
	if err := tx.QueryRow(
		`SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='inbox_items')`,
	).Scan(&exists); err != nil || exists == 0 {
		return nil // table doesn't exist yet; CREATE TABLE IF NOT EXISTS will handle it
	}

	// Rename task_id → target_id if needed (legacy had task_id)
	if hasColumnUpgrade(tx, "inbox_items", "task_id") && !hasColumnUpgrade(tx, "inbox_items", "target_id") {
		if _, err := tx.Exec(`ALTER TABLE inbox_items RENAME COLUMN task_id TO target_id`); err != nil {
			return fmt.Errorf("renaming task_id to target_id: %w", err)
		}
	}

	// Add missing columns with defaults matching 00001 baseline
	type colDef struct {
		name string
		ddl  string
	}
	cols := []colDef{
		{"waiting_user_ids", "TEXT NOT NULL DEFAULT '[]'"}, // legacy had DEFAULT '' without JSON
		{"target_id", "INTEGER"},
		{"item_class", "TEXT NOT NULL DEFAULT 'actionable'"},
		{"pinned", "INTEGER NOT NULL DEFAULT 0"},
		{"archived_at", "TEXT"},
		{"archive_reason", "TEXT DEFAULT ''"},
	}
	for _, c := range cols {
		if !hasColumnUpgrade(tx, "inbox_items", c.name) {
			stmt := fmt.Sprintf("ALTER TABLE inbox_items ADD COLUMN %s %s", c.name, c.ddl)
			if _, err := tx.Exec(stmt); err != nil {
				return fmt.Errorf("adding column %s: %w", c.name, err)
			}
		}
	}

	return nil
}
