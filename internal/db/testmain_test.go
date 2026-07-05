package db

import (
	"database/sql"
	"fmt"
	"os"
	"sync/atomic"
	"testing"

	_ "modernc.org/sqlite"
)

// templateReady is set to 1 after the template DDL cache has been built.
var templateReady atomic.Int32

// templateDDL holds the ordered list of DDL statements extracted from the
// template DB. Set once in buildTemplateDB, then read-only.
var templateDDL []string

// templateGooseRows holds the values to seed goose_db_version in every clone.
// Each element is a (version_id, is_applied) pair.
var templateGooseRows [][2]int64

// TestMain initialises the schema template once, then runs all tests.
//
// Why: applying goose migrations to every in-memory DB (545+ tests × ~1 s
// with the -race detector) exceeds the 10-minute CI timeout. By running goose
// once on a throwaway DB and caching the resulting DDL we can recreate an
// equivalent schema in ~milliseconds per test instead.
func TestMain(m *testing.M) {
	if err := buildTemplateDB(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: failed to build template DB: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// buildTemplateDB runs goose migrations on a throwaway in-memory DB, then
// extracts the DDL into templateDDL and the goose version rows into
// templateGooseRows for fast cloning.
func buildTemplateDB() error {
	sqlDB, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		return fmt.Errorf("opening template DB: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)
	defer sqlDB.Close()

	db := &DB{DB: sqlDB}
	if err := db.setPragmas(); err != nil {
		return fmt.Errorf("template pragmas: %w", err)
	}
	if err := db.migrate(); err != nil {
		return fmt.Errorf("template migrations: %w", err)
	}

	// Extract DDL for all user objects except FTS5 shadow tables and
	// goose_db_version (handled separately).
	rows, err := sqlDB.Query(`
		SELECT type, name, sql FROM sqlite_master
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
		return fmt.Errorf("querying template objects: %w", err)
	}
	defer rows.Close()

	var ddl []string
	for rows.Next() {
		var objType, name, stmt string
		if err := rows.Scan(&objType, &name, &stmt); err != nil {
			return fmt.Errorf("scanning template object: %w", err)
		}
		_ = objType // retained for ordering query; not needed here
		_ = name
		ddl = append(ddl, stmt)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterating template objects: %w", err)
	}

	// Extract goose version rows.
	vrows, err := sqlDB.Query(`SELECT version_id, is_applied FROM goose_db_version ORDER BY id`)
	if err != nil {
		return fmt.Errorf("querying goose version rows: %w", err)
	}
	defer vrows.Close()

	var gooseRows [][2]int64
	for vrows.Next() {
		var vid, applied int64
		if err := vrows.Scan(&vid, &applied); err != nil {
			return fmt.Errorf("scanning goose version row: %w", err)
		}
		gooseRows = append(gooseRows, [2]int64{vid, applied})
	}
	if err := vrows.Err(); err != nil {
		return fmt.Errorf("iterating goose version rows: %w", err)
	}

	templateDDL = ddl
	templateGooseRows = gooseRows
	templateReady.Store(1)
	return nil
}

// cloneTemplateDB creates a fresh in-memory database whose schema matches the
// migrated template. It replays templateDDL in a single transaction and seeds
// goose_db_version so that goose.Up() on the clone is a no-op.
//
// The returned *sql.DB is limited to 1 connection. The caller must Close it.
func cloneTemplateDB() (*sql.DB, error) {
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

	// Replay schema DDL.
	for _, stmt := range templateDDL {
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

	// Recreate goose_db_version with the same rows.
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
	for _, row := range templateGooseRows {
		if _, err := tx.Exec(`INSERT INTO goose_db_version (version_id, is_applied) VALUES (?, ?)`,
			row[0], row[1]); err != nil {
			tx.Rollback() //nolint:errcheck
			dst.Close()
			return nil, fmt.Errorf("inserting goose version row: %w", err)
		}
	}

	if err := tx.Commit(); err != nil {
		dst.Close()
		return nil, fmt.Errorf("committing clone tx: %w", err)
	}

	// Enable foreign key enforcement for correctness (not set by default in SQLite).
	if _, err := dst.Exec("PRAGMA foreign_keys=ON"); err != nil {
		dst.Close()
		return nil, fmt.Errorf("enabling foreign keys: %w", err)
	}

	return dst, nil
}
