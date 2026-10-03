package db

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSchemaDrift_FreshDatabaseHasNoMissingTables: every table schema.sql
// declares exists after a fresh migrate. This also keeps schema.sql honest —
// a table added to it without a migration (or left in it after a migration
// dropped it) fails here.
func TestSchemaDrift_FreshDatabaseHasNoMissingTables(t *testing.T) {
	d := openTestDB(t)

	require.GreaterOrEqual(t, len(declaredTables), 100, "schema.sql parse floor")
	assert.Contains(t, declaredTables, "external_connections")
	assert.Contains(t, declaredTables, "messages_fts", "virtual tables are declared too")

	missing, err := d.missingTables()
	require.NoError(t, err)
	assert.Empty(t, missing)
}

// dropTable drops table while goose keeps its migration recorded as applied —
// the state a renumbered branch migration leaves behind.
func dropTable(t *testing.T, d *DB, table string) {
	t.Helper()
	before, err := goose.GetDBVersion(d.DB)
	require.NoError(t, err)
	_, err = d.Exec(`PRAGMA foreign_keys = OFF`)
	require.NoError(t, err)
	_, err = d.Exec(`DROP TABLE "` + table + `"`)
	require.NoError(t, err)
	_, err = d.Exec(`PRAGMA foreign_keys = ON`)
	require.NoError(t, err)
	after, err := goose.GetDBVersion(d.DB)
	require.NoError(t, err)
	require.Equal(t, before, after, "goose must still record the migration as applied")
}

// tableDDL returns the stored SQL of a table and of the indexes and triggers
// on it, sorted, with SQLite's rename quoting, comments and whitespace
// normalized (a replay runs the migration with its comments stripped).
func tableDDL(t *testing.T, d *DB, table string) string {
	t.Helper()
	ddl := queryStrings(t, d, `SELECT COALESCE(sql, '') FROM sqlite_master WHERE tbl_name = '`+table+`' ORDER BY type, name`)
	joined := normalizeRenamedTables(strings.Join(ddl, "\n"))
	return whitespaceRe.ReplaceAllString(lineCommentRe.ReplaceAllString(joined, ""), " ")
}

// TestSchemaDrift_EveryDeclaredTableIsRepairedExactlyOrReported drops each
// declared table in turn: CheckSchemaDrift must either rebuild it exactly as
// a fresh migrate has it (table, indexes, triggers) or report it in a
// *SchemaDriftError. A replay that leaves an older shape — a later migration
// added a column or an index — fails here.
func TestSchemaDrift_EveryDeclaredTableIsRepairedExactlyOrReported(t *testing.T) {
	t.Parallel()
	fresh := openTestDB(t)
	repaired := 0
	for _, table := range declaredTables {
		want := tableDDL(t, fresh, table)
		d := openTestDB(t)
		dropTable(t, d, table)

		err := d.CheckSchemaDrift()
		if err == nil {
			assert.Equal(t, want, tableDDL(t, d, table), "%s: repaired table differs from a fresh migrate", table)
			repaired++
			continue
		}
		var drift *SchemaDriftError
		if assert.ErrorAs(t, err, &drift, table) {
			assert.Equal(t, []string{table}, missingNames(drift))
		}
	}
	assert.Positive(t, repaired, "no table is repairable: the replay path is dead")
}

func missingNames(e *SchemaDriftError) []string {
	names := make([]string, len(e.Missing))
	for i, m := range e.Missing {
		names[i] = m.Name
	}
	return names
}

// TestSchemaDrift_BurnedVersionDetectedAndRepaired replays the 2026-09-28
// incident: external_connections (00064, an idempotent CREATE TABLE IF NOT
// EXISTS) is missing while goose records v64 as applied. CheckSchemaDrift
// repairs it, and so does the next Open.
func TestSchemaDrift_BurnedVersionDetectedAndRepaired(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "burned.db")
	d, err := Open(path)
	require.NoError(t, err)
	dropTable(t, d, "external_connections")

	missing, err := d.missingTables()
	require.NoError(t, err)
	assert.Equal(t, []string{"external_connections"}, missing)

	require.NoError(t, d.CheckSchemaDrift())
	assertTableExists(t, d, "external_connections")
	_, err = d.Exec(`INSERT INTO external_connections (name) VALUES ('probe')`)
	require.NoError(t, err, "the repaired table must be usable")

	dropTable(t, d, "external_connections")
	require.NoError(t, d.Close())
	d2, err := Open(path)
	require.NoError(t, err)
	defer d2.Close()
	assertTableExists(t, d2, "external_connections")
}

// TestSchemaDrift_UnsafeReplaysReported: a missing table whose migration
// cannot be replayed safely is left missing and reported with its
// migration, and Open still succeeds — 00043 rewrites ids and moves
// watermarks; 00034 is all CREATE IF NOT EXISTS, but 00038 later adds
// memory_provenance.sender_id, so a replay would build the old shape.
func TestSchemaDrift_UnsafeReplaysReported(t *testing.T) {
	t.Parallel()
	for table, file := range map[string]string{
		"google_accounts":   "00043_google_accounts.sql",
		"memory_provenance": "00034_memory_digest_compare.sql",
	} {
		t.Run(table, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "drift.db")
			d, err := Open(path)
			require.NoError(t, err)
			dropTable(t, d, table)

			err = d.CheckSchemaDrift()
			var drift *SchemaDriftError
			require.ErrorAs(t, err, &drift)
			assert.Equal(t, []MissingTable{{Name: table, Migration: file}}, drift.Missing)
			assert.Contains(t, err.Error(), table+" ("+file+")")
			assertTableGone(t, d, table)

			require.NoError(t, d.Close())
			d2, err := Open(path)
			require.NoError(t, err, "a drifted database must still open")
			defer d2.Close()
			assertTableGone(t, d2, table)
		})
	}
}

// TestSchemaDrift_SkippedForNewerDatabase: a database a newer binary migrated
// is not judged against this binary's schema.sql, which may still declare a
// table the newer migrations dropped.
func TestSchemaDrift_SkippedForNewerDatabase(t *testing.T) {
	d := openTestDB(t)
	dropTable(t, d, "external_connections")
	latest, err := goose.GetDBVersion(d.DB)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO goose_db_version (version_id, is_applied) VALUES (?, 1)`, latest+1)
	require.NoError(t, err)

	require.NoError(t, d.CheckSchemaDrift())
	assertTableGone(t, d, "external_connections")
}

func TestReplayableMigrations(t *testing.T) {
	migrations, err := loadMigrations()
	require.NoError(t, err)
	replayable := replayableMigrations(migrations)

	assert.Contains(t, replayable, "00064_external_connections.sql",
		"a later foreign key REFERENCES does not block a replay")
	assert.NotContains(t, replayable, "00065_reminders.sql", "a seed is never replayed")
	assert.NotContains(t, replayable, "00034_memory_digest_compare.sql", "00038 later alters memory_provenance")
}

func TestIdempotentStatements(t *testing.T) {
	stmts := idempotentStatements(`
CREATE TABLE IF NOT EXISTS a (id INTEGER PRIMARY KEY, note TEXT DEFAULT '');
create  index if not exists idx_a ON a(id);
CREATE VIRTUAL TABLE IF NOT EXISTS a_fts USING fts5(note);
`)
	require.Len(t, stmts, 3)
	assert.True(t, strings.HasPrefix(stmts[1], "create  index"))

	for _, up := range []string{
		"CREATE TABLE IF NOT EXISTS a (id INTEGER);\nALTER TABLE b ADD COLUMN c TEXT;",
		"CREATE TABLE a (id INTEGER);",
		"CREATE TABLE IF NOT EXISTS a (id INTEGER);\nINSERT OR IGNORE INTO a (id) VALUES (1);",
		"CREATE TABLE IF NOT EXISTS a (id INTEGER);\nINSERT INTO a SELECT * FROM b;",
	} {
		assert.Nil(t, idempotentStatements(up), up)
	}
}
