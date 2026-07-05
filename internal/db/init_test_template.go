package db

import (
	"database/sql"
	"fmt"
)

// InitTestTemplate migrates a throw-away in-memory database once, caches the
// resulting DDL + goose version rows, and installs openMemoryHook so that every
// subsequent Open(":memory:") call returns a pre-migrated clone instead of
// running goose from scratch.
//
// Call this from TestMain in any package whose tests make heavy use of
// db.Open(":memory:"). Without it every Open(":memory:") runs the full goose
// migration suite, which under -race can exceed Go's default 10-minute test
// timeout on slow CI runners.
//
// Safe to call multiple times (second call is a no-op).
func InitTestTemplate() error {
	if openMemoryHook != nil {
		return nil // already initialised
	}

	sqlDB, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		return fmt.Errorf("opening template DB: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)
	defer sqlDB.Close()

	tmpl := &DB{DB: sqlDB}
	if err := tmpl.setPragmas(); err != nil {
		return fmt.Errorf("template pragmas: %w", err)
	}
	if err := tmpl.migrate(); err != nil {
		return fmt.Errorf("template migrations: %w", err)
	}

	// Extract DDL for all user objects except FTS5 shadow tables and
	// goose_db_version (handled separately below).
	rows, err := sqlDB.Query(`
		SELECT sql FROM sqlite_master
		WHERE sql IS NOT NULL
		  AND name NOT LIKE 'sqlite_%'
		  AND name NOT LIKE '%_config'
		  AND name NOT LIKE '%_data'
		  AND name NOT LIKE '%_idx'
		  AND name NOT LIKE '%_content'
		  AND name NOT LIKE '%_docsize'
		  AND name NOT LIKE '%_rowid'
		  AND name != 'goose_db_version'
		ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END, name`)
	if err != nil {
		return fmt.Errorf("querying template DDL: %w", err)
	}
	defer rows.Close()

	var ddl []string
	for rows.Next() {
		var stmt string
		if err := rows.Scan(&stmt); err != nil {
			return fmt.Errorf("scanning DDL: %w", err)
		}
		ddl = append(ddl, stmt)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterating DDL: %w", err)
	}

	// Extract goose version rows.
	vrows, err := sqlDB.Query(`SELECT version_id, is_applied FROM goose_db_version ORDER BY id`)
	if err != nil {
		return fmt.Errorf("querying goose rows: %w", err)
	}
	defer vrows.Close()

	var gooseRows [][2]int64
	for vrows.Next() {
		var vid, applied int64
		if err := vrows.Scan(&vid, &applied); err != nil {
			return fmt.Errorf("scanning goose row: %w", err)
		}
		gooseRows = append(gooseRows, [2]int64{vid, applied})
	}
	if err := vrows.Err(); err != nil {
		return fmt.Errorf("iterating goose rows: %w", err)
	}

	// Install the hook — from this point on, Open(":memory:") returns a clone.
	openMemoryHook = func() (*DB, error) {
		dst, err := sql.Open("sqlite", ":memory:")
		if err != nil {
			return nil, fmt.Errorf("opening clone DB: %w", err)
		}
		dst.SetMaxOpenConns(1)

		tx, err := dst.Begin()
		if err != nil {
			dst.Close()
			return nil, fmt.Errorf("beginning clone tx: %w", err)
		}

		for _, stmt := range ddl {
			if _, err := tx.Exec(stmt); err != nil {
				tx.Rollback() //nolint:errcheck
				dst.Close()
				preview := stmt
				if len(preview) > 60 {
					preview = preview[:60]
				}
				return nil, fmt.Errorf("executing DDL %q: %w", preview, err)
			}
		}

		if _, err := tx.Exec(`CREATE TABLE goose_db_version (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			version_id INTEGER NOT NULL,
			is_applied INTEGER NOT NULL,
			tstamp TIMESTAMP DEFAULT (datetime('now'))
		)`); err != nil {
			tx.Rollback() //nolint:errcheck
			dst.Close()
			return nil, fmt.Errorf("creating goose_db_version: %w", err)
		}
		for _, row := range gooseRows {
			if _, err := tx.Exec(
				`INSERT INTO goose_db_version (version_id, is_applied) VALUES (?, ?)`,
				row[0], row[1],
			); err != nil {
				tx.Rollback() //nolint:errcheck
				dst.Close()
				return nil, fmt.Errorf("inserting goose row: %w", err)
			}
		}

		if err := tx.Commit(); err != nil {
			dst.Close()
			return nil, fmt.Errorf("committing clone tx: %w", err)
		}

		db := &DB{DB: dst}
		if err := db.setPragmas(); err != nil {
			dst.Close()
			return nil, fmt.Errorf("clone pragmas: %w", err)
		}
		return db, nil
	}

	return nil
}
