package adopt

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"watchtower/internal/hub/state"
)

// foldedColumn is one column the Swift hub adds by ALTER TABLE (when its
// file predates the column) and 00001 folds into its CREATE statements,
// with the Swift ALTER's type.
type foldedColumn struct{ table, column, typ string }

// foldedIn is every ALTER TABLE column of the Swift hub (HubSyncState.swift
// and HubSyncState+Keys.swift; TestFoldedInMatchesTheSwiftAlters pins the
// list to that source). 00001 is IF NOT EXISTS over the Swift tables, so a
// Swift file without one of them would never get it from the migrations.
var foldedIn = []foldedColumn{
	{"relay_processed", "echo", "BLOB"},
	{"relay_processed", "done_seq", "INTEGER"},
	{"devices", "typing_requested", "INTEGER NOT NULL DEFAULT 0"},
	{"devices", "permissions_allowed", "INTEGER NOT NULL DEFAULT 0"},
	{"devices", "permissions_requested", "INTEGER NOT NULL DEFAULT 0"},
	{"devices", "start_sessions_granted", "INTEGER NOT NULL DEFAULT 0"},
	{"devices", "signing_key", "BLOB"},
	{"devices", "agreement_key", "BLOB"},
	{"devices", "link_nonce", "TEXT"},
	{"devices", "last_seq", "INTEGER"},
	{"link_refusals", "agreement_key", "BLOB"},
	{"link_codes", "confirm_nonces_drawn", "INTEGER NOT NULL DEFAULT 0"},
	{"pending_devices", "typing_requested", "INTEGER NOT NULL DEFAULT 0"},
	{"pending_devices", "confirm_nonce", "BLOB"},
	{"pending_devices", "start_sessions", "INTEGER NOT NULL DEFAULT 1"},
	{"revoked_devices", "name", "TEXT"},
	{"revoked_devices", "scope", "TEXT"},
	{"slice_state", "wire_name", "TEXT"},
}

// CheckSwiftFile checks, read-only through pragma_table_info, that every
// folded-in column is present in the Swift file at path (in each of those
// tables that exists; 00001 creates a missing table whole). One missing is
// ErrSwiftSchema. Adoption checks the copy after repairSwiftCopy added what
// an older Swift build had not added yet.
func CheckSwiftFile(path string) error {
	db, err := rawOpen(path, openSwiftRO)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	return checkFolded(db)
}

func checkFolded(db *sql.DB) error {
	for _, c := range foldedIn {
		has, tableExists, err := hasColumn(db, c.table, c.column)
		if err != nil {
			return fmt.Errorf("%w: %w", ErrSwiftCorrupt, err)
		}
		if tableExists && !has {
			return fmt.Errorf("%w: %s.%s", ErrSwiftSchema, c.table, c.column)
		}
	}
	return nil
}

func hasColumn(db *sql.DB, table, column string) (has, tableExists bool, err error) {
	var n int
	if err := db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&n); err != nil {
		return false, false, err
	}
	if n == 0 {
		return false, false, nil
	}
	if err := db.QueryRow(`SELECT count(*) FROM pragma_table_info(?) WHERE name = ?`, table, column).Scan(&n); err != nil {
		return false, true, err
	}
	return n == 1, true, nil
}

// repairSwiftCopy adds to the copy the folded-in columns an older Swift
// build had not added yet, exactly as the Swift hub's own upgrade does
// (addMissingColumns: the same type and default), before the commit point.
func repairSwiftCopy(db *sql.DB) error {
	for _, c := range foldedIn {
		has, tableExists, err := hasColumn(db, c.table, c.column)
		if err != nil {
			return fmt.Errorf("%w: %w", ErrSwiftCorrupt, err)
		}
		if !tableExists || has {
			continue
		}
		// Names and types are the constants above, never input.
		if _, err := db.Exec(`ALTER TABLE ` + c.table + ` ADD COLUMN ` + c.column + ` ` + c.typ); err != nil {
			return fmt.Errorf("%w: adding %s.%s: %w", ErrSwiftSchema, c.table, c.column, err)
		}
	}
	if _, exists, err := hasColumn(db, "slice_state", "wire_name"); err != nil || !exists {
		return err
	}
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS slice_state_by_wire ON slice_state (wire_name)`); err != nil {
		return fmt.Errorf("%w: %w", ErrSwiftSchema, err)
	}
	return nil
}

var uuidRE = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

// checkHubID refuses a copy without a usable hub_meta.hub_id: the zones are
// named after it, and a new one would orphan every phone.
func checkHubID(db *sql.DB) error {
	var id string
	err := db.QueryRow(`SELECT value FROM hub_meta WHERE key = 'hub_id'`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && !uuidRE.MatchString(id)) {
		return ErrSwiftHubID
	}
	if err != nil {
		return fmt.Errorf("%w: %w", ErrSwiftHubID, err)
	}
	return nil
}

// dryRunMigrations migrates a scratch copy of the verified copy and compares
// its tables and columns with a fresh Go sidecar's, so the migrate step
// after the commit point cannot fail on this file's schema (a base column
// 00001 would not add, a later migration that does not apply). Both scratch
// files are removed.
func dryRunMigrations(copyPath, scratch string) error {
	dry, fresh := filepath.Join(scratch, "dry"), filepath.Join(scratch, "fresh")
	defer func() { _ = os.RemoveAll(scratch) }()
	if err := os.MkdirAll(dry, 0o700); err != nil {
		return fmt.Errorf("adopt: the dry run: %w", err)
	}
	if err := copyFile(copyPath, filepath.Join(dry, state.FileName)); err != nil {
		return err
	}
	st, err := state.Open(dry)
	if err != nil {
		return fmt.Errorf("%w: the migrations do not apply: %w", ErrSwiftSchema, err)
	}
	_ = st.Close()
	fs, err := state.Open(fresh)
	if err != nil {
		return err
	}
	_ = fs.Close()
	want, err := columnsOf(filepath.Join(fresh, state.FileName))
	if err != nil {
		return err
	}
	got, err := columnsOf(filepath.Join(dry, state.FileName))
	if err != nil {
		return err
	}
	for tc := range want {
		if !got[tc] {
			return fmt.Errorf("%w: %s", ErrSwiftSchema, tc)
		}
	}
	return nil
}

// columnsOf is every "table.column" of a file's tables (goose's excluded).
func columnsOf(path string) (map[string]bool, error) {
	db, err := rawOpen(path, openRO)
	if err != nil {
		return nil, err
	}
	defer func() { _ = db.Close() }()
	rows, err := db.Query(`SELECT m.name || '.' || p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p
		WHERE m.type = 'table' AND m.name NOT LIKE 'goose%' AND m.name NOT LIKE 'sqlite%'`)
	if err != nil {
		return nil, fmt.Errorf("adopt: reading a schema: %w", err)
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var tc string
		if err := rows.Scan(&tc); err != nil {
			return nil, fmt.Errorf("adopt: reading a schema: %w", err)
		}
		out[tc] = true
	}
	return out, rows.Err()
}
