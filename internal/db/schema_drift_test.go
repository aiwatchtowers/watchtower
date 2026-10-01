package db

import (
	"errors"
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

	tables := schemaTables()
	require.GreaterOrEqual(t, len(tables), 100, "schema.sql parse floor")
	assert.Contains(t, tables, "external_connections")
	assert.Contains(t, tables, "messages_fts", "virtual tables are declared too")

	missing, err := d.missingTables()
	require.NoError(t, err)
	assert.Empty(t, missing)
}

// burnedVersionDB opens a file database and drops table while goose keeps its
// migration recorded as applied — the state a renumbered branch migration
// leaves behind.
func burnedVersionDB(t *testing.T, table string) (*DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "burned.db")
	d, err := Open(path)
	require.NoError(t, err)
	before, err := goose.GetDBVersion(d.DB)
	require.NoError(t, err)

	_, err = d.Exec(`PRAGMA foreign_keys = OFF`)
	require.NoError(t, err)
	_, err = d.Exec(`DROP TABLE ` + table)
	require.NoError(t, err)
	_, err = d.Exec(`PRAGMA foreign_keys = ON`)
	require.NoError(t, err)

	after, err := goose.GetDBVersion(d.DB)
	require.NoError(t, err)
	require.Equal(t, before, after, "goose must still record the migration as applied")
	return d, path
}

// TestSchemaDrift_BurnedVersionDetectedAndRepaired replays the 2026-09-28
// incident: external_connections (00064, an idempotent CREATE TABLE IF NOT
// EXISTS) is missing while goose records v64 as applied. It is detected with
// its migration named, and repaired — both by CheckSchemaDrift and by the
// next Open.
func TestSchemaDrift_BurnedVersionDetectedAndRepaired(t *testing.T) {
	d, path := burnedVersionDB(t, "external_connections")

	missing, err := d.missingTables()
	require.NoError(t, err)
	require.Len(t, missing, 1)
	assert.Equal(t, "external_connections", missing[0].Name)
	assert.Equal(t, "00064_external_connections.sql", missing[0].Migration)

	require.NoError(t, d.CheckSchemaDrift())
	assertTableExists(t, d, "external_connections")
	_, err = d.Exec(`INSERT INTO external_connections (name) VALUES ('probe')`)
	require.NoError(t, err, "the repaired table must be usable")

	// The same state is repaired by Open itself.
	_, err = d.Exec(`DROP TABLE external_connections`)
	require.NoError(t, err)
	require.NoError(t, d.Close())
	d2, err := Open(path)
	require.NoError(t, err)
	defer d2.Close()
	assertTableExists(t, d2, "external_connections")
}

// TestSchemaDrift_NonIdempotentMigrationReported: a missing table whose
// migration cannot be replayed safely (00043 also rewrites ids and moves
// watermarks) is not touched; CheckSchemaDrift returns a
// *SchemaDriftError naming the table and its migration, and Open still
// succeeds.
func TestSchemaDrift_NonIdempotentMigrationReported(t *testing.T) {
	d, path := burnedVersionDB(t, "google_accounts")

	err := d.CheckSchemaDrift()
	var drift *SchemaDriftError
	require.True(t, errors.As(err, &drift), "want *SchemaDriftError, got %v", err)
	require.Len(t, drift.Missing, 1)
	assert.Equal(t, "google_accounts", drift.Missing[0].Name)
	assert.Equal(t, "00043_google_accounts.sql", drift.Missing[0].Migration)
	assert.Contains(t, err.Error(), "google_accounts (00043_google_accounts.sql)")
	assertTableGone(t, d, "google_accounts")

	require.NoError(t, d.Close())
	d2, err := Open(path)
	require.NoError(t, err, "a drifted database must still open")
	defer d2.Close()
	assertTableGone(t, d2, "google_accounts")
}

func TestIdempotentStatements(t *testing.T) {
	stmts := idempotentStatements(`-- +goose Up
-- a comment; with a semicolon
CREATE TABLE IF NOT EXISTS a (id INTEGER PRIMARY KEY, note TEXT DEFAULT ''); -- trailing
create  index if not exists idx_a ON a(id);
CREATE VIRTUAL TABLE IF NOT EXISTS a_fts USING fts5(note);
INSERT OR IGNORE INTO a (id) VALUES (1);
`)
	require.Len(t, stmts, 4)
	assert.True(t, strings.HasPrefix(stmts[1], "create  index"))

	for _, up := range []string{
		"CREATE TABLE IF NOT EXISTS a (id INTEGER);\nALTER TABLE b ADD COLUMN c TEXT;",
		"CREATE TABLE a (id INTEGER);",
		"CREATE TABLE IF NOT EXISTS a (id INTEGER);\nINSERT INTO a SELECT * FROM b;",
		"-- +goose StatementBegin\nCREATE TRIGGER IF NOT EXISTS t AFTER INSERT ON a BEGIN SELECT 1; END;\n-- +goose StatementEnd",
	} {
		assert.Nil(t, idempotentStatements(up), up)
	}
}
