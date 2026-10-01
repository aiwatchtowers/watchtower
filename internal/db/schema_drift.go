package db

import (
	"fmt"
	"io/fs"
	"log/slog"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/pressly/goose/v3"
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
		return m.Name + " (schema.sql)"
	}
	return m.Name + " (" + m.Migration + ")"
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
		"back up the database and create each listed table, with its indexes, from its CREATE statements "+
		"in internal/db/schema.sql — do not re-run the migration's data rewrites)",
		strings.Join(names, ", "))
}

var (
	createTableRe = regexp.MustCompile(`(?im)^\s*CREATE\s+(?:VIRTUAL\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"?([A-Za-z_][A-Za-z0-9_]*)"?`)
	lineCommentRe = regexp.MustCompile(`--[^\n]*`)
	whitespaceRe  = regexp.MustCompile(`\s+`)
	referencesRe  = regexp.MustCompile(`(?i)REFERENCES\s*$`)

	// declaredTables are the table names schema.sql declares, in file order.
	declaredTables = createdTables(Schema)
)

// createdTables returns the names of the tables sql creates.
func createdTables(sql string) []string {
	var names []string
	for _, m := range createTableRe.FindAllStringSubmatch(sql, -1) {
		names = append(names, m[1])
	}
	return names
}

// CheckSchemaDrift finds the tables schema.sql declares that the database
// lacks, re-applies each one's creating migration when replayableMigrations
// judges it safe, and returns a *SchemaDriftError naming the tables still
// missing, or nil. A database migrated past this binary's newest migration
// is skipped: this binary's schema.sql may still declare tables a newer
// migration dropped.
func (db *DB) CheckSchemaDrift() error {
	missing, err := db.missingTables()
	if err != nil || len(missing) == 0 {
		return err
	}
	migrations, err := loadMigrations()
	if err != nil {
		return err
	}
	if newer, err := db.migratedPastBinary(migrations); err != nil || newer {
		return err
	}

	creators := map[string]string{}
	for _, mig := range migrations {
		for _, name := range mig.creates {
			creators[name] = mig.file
		}
	}
	replayable := replayableMigrations(migrations)
	replayed := map[string]bool{}
	for _, name := range missing {
		file := creators[name]
		stmts, ok := replayable[file]
		if !ok || replayed[file] {
			continue
		}
		replayed[file] = true
		if err := db.replay(stmts); err != nil {
			// The table stays missing and is reported below.
			slog.Warn("could not re-apply a migration skipped under a reused goose version", "migration", file, "error", err)
			continue
		}
		slog.Warn("re-applied a migration skipped under a reused goose version", "table", name, "migration", file)
	}

	still, err := db.missingTables()
	if err != nil || len(still) == 0 {
		return err
	}
	drift := &SchemaDriftError{}
	for _, name := range still {
		drift.Missing = append(drift.Missing, MissingTable{Name: name, Migration: creators[name]})
	}
	return drift
}

// missingTables returns the declared tables the database does not have.
func (db *DB) missingTables() ([]string, error) {
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
	var missing []string
	for _, name := range declaredTables {
		if !present[name] {
			missing = append(missing, name)
		}
	}
	return missing, nil
}

// migratedPastBinary reports whether the database records a goose version
// newer than the newest migration embedded in this binary.
func (db *DB) migratedPastBinary(migrations []migration) (bool, error) {
	v, err := goose.GetDBVersion(db.DB)
	if err != nil {
		return false, fmt.Errorf("reading goose version: %w", err)
	}
	return len(migrations) > 0 && v > migrations[len(migrations)-1].version, nil
}

// replay runs stmts in one transaction.
func (db *DB) replay(stmts []string) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning replay: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	for _, s := range stmts {
		if _, err := tx.Exec(s); err != nil {
			return fmt.Errorf("executing %q: %w", firstLine(s), err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing replay: %w", err)
	}
	return nil
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return line
}

// migration is the Up section of one embedded migration file.
type migration struct {
	file    string
	version int64
	up      string // comments stripped
	creates []string
	// blocks is set when Up holds a StatementBegin/End block (a trigger
	// body); such a migration is never replayed.
	blocks bool
}

// loadMigrations reads every embedded migration, in version order.
func loadMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrationsFS, "migrations")
	if err != nil {
		return nil, fmt.Errorf("reading embedded migrations: %w", err)
	}
	var out []migration
	for _, e := range entries {
		if path.Ext(e.Name()) != ".sql" {
			continue
		}
		prefix, _, _ := strings.Cut(e.Name(), "_")
		version, err := strconv.ParseInt(prefix, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("migration %s has no version prefix: %w", e.Name(), err)
		}
		raw, err := fs.ReadFile(migrationsFS, path.Join("migrations", e.Name()))
		if err != nil {
			return nil, fmt.Errorf("reading migration %s: %w", e.Name(), err)
		}
		rawUp, _, _ := strings.Cut(string(raw), "-- +goose Down")
		up := lineCommentRe.ReplaceAllString(rawUp, "")
		out = append(out, migration{
			file:    e.Name(),
			version: version,
			up:      up,
			creates: createdTables(up),
			blocks:  strings.Contains(rawUp, "+goose StatementBegin"),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].version < out[j].version })
	return out, nil
}

// replayableMigrations returns, by file, the statements of each migration
// that can be re-run safely on a database that recorded it as applied but
// lacks its tables: its Up is made only of CREATE ... IF NOT EXISTS
// statements, and no later migration touches a table it creates (an ALTER,
// an index, a rebuild, a seed or a drop would leave a replayed table in an
// older shape than the rest of the database). A later foreign key that
// REFERENCES the table does not count as touching it.
func replayableMigrations(migrations []migration) map[string][]string {
	out := map[string][]string{}
	for i, mig := range migrations {
		if mig.blocks {
			continue
		}
		stmts := idempotentStatements(mig.up)
		if stmts == nil || laterMigrationTouches(migrations[i+1:], mig.creates) {
			continue
		}
		out[mig.file] = stmts
	}
	return out
}

func laterMigrationTouches(later []migration, tables []string) bool {
	for _, name := range tables {
		word := regexp.MustCompile(`(?i)\b` + regexp.QuoteMeta(name) + `\b`)
		for _, mig := range later {
			for _, loc := range word.FindAllStringIndex(mig.up, -1) {
				if !referencesRe.MatchString(mig.up[:loc[0]]) {
					return true
				}
			}
		}
	}
	return false
}

// idempotentPrefixes are the only statement shapes a replay runs. Seeds
// (INSERT OR IGNORE) are left out on purpose: replaying one would bring back
// rows the owner deleted.
var idempotentPrefixes = []string{
	"CREATE TABLE IF NOT EXISTS ",
	"CREATE VIRTUAL TABLE IF NOT EXISTS ",
	"CREATE INDEX IF NOT EXISTS ",
	"CREATE UNIQUE INDEX IF NOT EXISTS ",
}

// idempotentStatements splits a comment-free Up section into statements and
// returns them when every one is idempotent, or nil when any is not (an
// ALTER, a table rebuild, a seed, a data rewrite). The split is naive about
// ';' inside string literals; a statement it cuts apart fails the prefix
// check or the replay, and never runs half-applied (the replay is one
// transaction).
func idempotentStatements(up string) []string {
	var stmts []string
	for _, s := range strings.Split(up, ";") {
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
