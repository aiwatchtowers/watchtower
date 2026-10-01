package db

import (
	"fmt"
	"io/fs"
	"log/slog"
	"path"
	"regexp"
	"sort"
	"strings"
	"sync"
)

// Schema drift: goose tracks applied migrations by version number only. A
// branch build that applied its own migration under number N, renumbered
// before merge, leaves the database recording N as applied while the
// migration main ships as N never ran — nothing fails at migrate time and the
// gap surfaces much later as "no such table". Open compares the tables
// schema.sql declares against sqlite_master after every migrate, repairs what
// it safely can and reports the rest.

// MissingTable is a table schema.sql declares but the database lacks.
type MissingTable struct {
	Name string
	// Migration is the embedded migration file whose Up creates the table,
	// or "" when no migration creates it under that name (a rename-built
	// table).
	Migration string
}

func (m MissingTable) String() string {
	if m.Migration == "" {
		return m.Name
	}
	return m.Name + " (" + m.Migration + ")"
}

var createTableRe = regexp.MustCompile(`(?im)^\s*CREATE\s+(?:VIRTUAL\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"?([A-Za-z_][A-Za-z0-9_]*)"?`)

var (
	declaredTablesOnce sync.Once
	declaredTables     []string
)

// schemaTables returns the table names schema.sql declares, in file order.
func schemaTables() []string {
	declaredTablesOnce.Do(func() {
		for _, m := range createTableRe.FindAllStringSubmatch(Schema, -1) {
			declaredTables = append(declaredTables, m[1])
		}
	})
	return declaredTables
}

// MissingTables returns the tables schema.sql declares that the database
// does not have, each with the migration that should have created it.
func (db *DB) MissingTables() ([]MissingTable, error) {
	rows, err := db.Query(`SELECT name FROM sqlite_master WHERE type = 'table'`)
	if err != nil {
		return nil, fmt.Errorf("listing tables: %w", err)
	}
	defer rows.Close()
	present := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, fmt.Errorf("scanning table name: %w", err)
		}
		present[name] = true
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing tables: %w", err)
	}

	var missing []MissingTable
	for _, name := range schemaTables() {
		if !present[name] {
			missing = append(missing, MissingTable{Name: name})
		}
	}
	if len(missing) == 0 {
		return nil, nil
	}
	creators, err := tableCreators()
	if err != nil {
		return nil, err
	}
	for i := range missing {
		missing[i].Migration = creators[missing[i].Name]
	}
	return missing, nil
}

// tableCreators maps each table name to the last embedded migration whose Up
// section creates it.
func tableCreators() (map[string]string, error) {
	files, err := migrationFiles()
	if err != nil {
		return nil, err
	}
	creators := map[string]string{}
	for _, f := range files {
		up, err := migrationUp(f)
		if err != nil {
			return nil, err
		}
		for _, m := range createTableRe.FindAllStringSubmatch(up, -1) {
			creators[m[1]] = f
		}
	}
	return creators, nil
}

// migrationFiles lists the embedded migration file names in version order
// (the zero-padded prefix makes lexical order the version order).
func migrationFiles() ([]string, error) {
	entries, err := fs.ReadDir(migrationsFS, "migrations")
	if err != nil {
		return nil, fmt.Errorf("reading embedded migrations: %w", err)
	}
	var names []string
	for _, e := range entries {
		if path.Ext(e.Name()) == ".sql" {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// migrationUp returns the Up section of an embedded migration file.
func migrationUp(file string) (string, error) {
	raw, err := fs.ReadFile(migrationsFS, path.Join("migrations", file))
	if err != nil {
		return "", fmt.Errorf("reading migration %s: %w", file, err)
	}
	up, _, _ := strings.Cut(string(raw), "-- +goose Down")
	return up, nil
}

// idempotentPrefixes are the only statement shapes RepairMissingTables
// replays: re-running such a migration on a database that already has part
// of it cannot change or duplicate anything.
var idempotentPrefixes = []string{
	"CREATE TABLE IF NOT EXISTS ",
	"CREATE VIRTUAL TABLE IF NOT EXISTS ",
	"CREATE INDEX IF NOT EXISTS ",
	"CREATE UNIQUE INDEX IF NOT EXISTS ",
	"INSERT OR IGNORE INTO ",
}

var lineCommentRe = regexp.MustCompile(`--[^\n]*`)
var whitespaceRe = regexp.MustCompile(`\s+`)

// idempotentStatements splits a migration's Up section into statements and
// returns them when every one is idempotent, or nil when any is not (an
// ALTER, a table rebuild, a trigger body, a data rewrite).
func idempotentStatements(up string) []string {
	if strings.Contains(up, "+goose StatementBegin") {
		return nil
	}
	var stmts []string
	for _, s := range strings.Split(lineCommentRe.ReplaceAllString(up, ""), ";") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		head := strings.ToUpper(whitespaceRe.ReplaceAllString(s, " "))
		ok := false
		for _, p := range idempotentPrefixes {
			if strings.HasPrefix(head, p) {
				ok = true
				break
			}
		}
		if !ok {
			return nil
		}
		stmts = append(stmts, s)
	}
	return stmts
}

// RepairMissingTables re-applies, in one transaction, the migrations that
// create a missing table when that migration's Up is made only of idempotent
// statements (CREATE ... IF NOT EXISTS, INSERT OR IGNORE) — the shape of every
// incident so far. It returns the tables still missing afterwards: those whose
// migration is not idempotent, or that no migration creates by name.
func (db *DB) RepairMissingTables() (repaired, remaining []MissingTable, err error) {
	missing, err := db.MissingTables()
	if err != nil || len(missing) == 0 {
		return nil, nil, err
	}

	type replay struct {
		file  string
		stmts []string
	}
	var replays []replay
	seen := map[string]bool{}
	for _, m := range missing {
		if m.Migration == "" || seen[m.Migration] {
			continue
		}
		seen[m.Migration] = true
		up, err := migrationUp(m.Migration)
		if err != nil {
			return nil, nil, err
		}
		if stmts := idempotentStatements(up); stmts != nil {
			replays = append(replays, replay{file: m.Migration, stmts: stmts})
		}
	}
	if len(replays) > 0 {
		tx, err := db.Begin()
		if err != nil {
			return nil, nil, fmt.Errorf("beginning schema repair: %w", err)
		}
		defer func() { _ = tx.Rollback() }()
		for _, r := range replays {
			for _, s := range r.stmts {
				if _, err := tx.Exec(s); err != nil {
					return nil, nil, fmt.Errorf("re-applying %s: %w", r.file, err)
				}
			}
		}
		if err := tx.Commit(); err != nil {
			return nil, nil, fmt.Errorf("committing schema repair: %w", err)
		}
	}

	remaining, err = db.MissingTables()
	if err != nil {
		return nil, nil, err
	}
	still := map[string]bool{}
	for _, m := range remaining {
		still[m.Name] = true
	}
	for _, m := range missing {
		if !still[m.Name] {
			repaired = append(repaired, m)
		}
	}
	return repaired, remaining, nil
}

// SchemaDriftError reports tables the database still lacks after repair.
type SchemaDriftError struct {
	Missing []MissingTable
}

func (e *SchemaDriftError) Error() string {
	names := make([]string, len(e.Missing))
	for i, m := range e.Missing {
		names[i] = m.String()
	}
	return fmt.Sprintf("database is missing tables its recorded migration version should have created: %s "+
		"(a branch build probably applied a different migration under the same goose version; "+
		"back up the database and apply each listed migration's Up section by hand)",
		strings.Join(names, ", "))
}

// CheckSchemaDrift repairs what RepairMissingTables can and returns a
// *SchemaDriftError naming the tables still missing, or nil.
func (db *DB) CheckSchemaDrift() error {
	repaired, remaining, err := db.RepairMissingTables()
	if err != nil {
		return fmt.Errorf("checking schema drift: %w", err)
	}
	for _, m := range repaired {
		slog.Warn("re-applied a migration skipped under a reused goose version", "table", m.Name, "migration", m.Migration)
	}
	if len(remaining) > 0 {
		return &SchemaDriftError{Missing: remaining}
	}
	return nil
}
