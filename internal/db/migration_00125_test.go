package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// openAt124 returns a database file rolled back to goose version 124 (then
// changed by prepare), with what its migrations produced on a fresh open for
// comparison.
func openAt124(t *testing.T, prepare func(*DB)) (path, wantTable, wantView string) {
	t.Helper()
	path = filepath.Join(t.TempDir(), "w.db")
	d, err := Open(path)
	require.NoError(t, err)
	defer d.Close()
	wantTable, wantView = agentLogSchemaSQL(t, d)
	require.NoError(t, goose.DownTo(d.DB, "migrations", 124))
	prepare(d)
	return path, wantTable, wantView
}

func agentLogSchemaSQL(t *testing.T, d *DB) (table, view string) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT sql FROM sqlite_master WHERE name = 'agent_log_events'`).Scan(&table))
	require.NoError(t, d.QueryRow(`SELECT sql FROM sqlite_master WHERE name = 'agent_log_session_totals'`).Scan(&view))
	return table, view
}

// reopenAndCheck opens the file the way every process does and asserts it
// reaches the latest version with 00125's schema.
func reopenAndCheck(t *testing.T, path, wantTable, wantView string) {
	t.Helper()
	d, err := Open(path)
	require.NoError(t, err)
	defer d.Close()
	latest, err := goose.GetDBVersion(d.DB)
	require.NoError(t, err)
	want, err := embeddedMigrationVersions()
	require.NoError(t, err)
	assert.Equal(t, want[len(want)-1], latest)
	assert.True(t, d.schemaCurrent())
	table, view := agentLogSchemaSQL(t, d)
	assert.Equal(t, wantTable, table)
	assert.Equal(t, wantView, view)
}

func TestMigration00125_FromVersion124(t *testing.T) {
	path, wantTable, wantView := openAt124(t, func(d *DB) {
		for _, c := range columns00125 {
			var n int
			require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('agent_log_events') WHERE name = ?`, c.name).Scan(&n))
			require.Zero(t, n, "Down removes %s", c.name)
		}
	})
	reopenAndCheck(t, path, wantTable, wantView)
}

// #667: a branch build applied 00125's columns as its own version 124, so
// the file recorded 124 with the columns present and without main's 00124
// table; every later open failed with "duplicate column spawned_agent_id".
// It now opens, reaches the latest version, and the drift repair replays
// 00124.
func TestMigration00125_ColumnsAlreadyPresent(t *testing.T) {
	path, wantTable, wantView := openAt124(t, func(d *DB) {
		for _, c := range columns00125 {
			_, err := d.Exec(c.ddl)
			require.NoError(t, err)
		}
		_, err := d.Exec(`DROP TABLE review_checks`)
		require.NoError(t, err)
	})
	reopenAndCheck(t, path, wantTable, wantView)

	d, err := Open(path)
	require.NoError(t, err)
	defer d.Close()
	require.NoError(t, d.CheckSchemaDrift(), "00124's review_checks is replayed")
}
