package agentlogdb

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestOpen_SchemaAndPerms(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentlog.db")
	d, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })

	objects := map[string]string{}
	rows, err := d.Query(`SELECT name, type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var name, typ string
		require.NoError(t, rows.Scan(&name, &typ))
		objects[name] = typ
	}
	require.NoError(t, rows.Err())
	for _, table := range []string{"agent_log_files", "agent_log_sessions", "agent_log_events", "agent_log_meta", "agent_log_import"} {
		assert.Equal(t, "table", objects[table], table)
	}
	assert.Equal(t, "view", objects["agent_log_session_totals"])
	for _, idx := range []string{"idx_agent_log_events_session", "idx_agent_log_events_kind", "idx_agent_log_sessions_project"} {
		assert.Equal(t, "index", objects[idx], idx)
	}

	var fks int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM pragma_foreign_key_list('agent_log_sessions')`).Scan(&fks))
	assert.Zero(t, fks, "no foreign key reaches watchtower.db's projects or terminal_sessions")
	var parent string
	require.NoError(t, d.QueryRow(`SELECT "table" FROM pragma_foreign_key_list('agent_log_events')`).Scan(&parent))
	assert.Equal(t, "agent_log_sessions", parent, "events still cascade from their session")

	var mode string
	require.NoError(t, d.QueryRow(`PRAGMA journal_mode`).Scan(&mode))
	assert.Equal(t, "wal", mode)
	var fkOn int
	require.NoError(t, d.QueryRow(`PRAGMA foreign_keys`).Scan(&fkOn))
	assert.Equal(t, 1, fkOn)

	// A write while the handle is open makes SQLite create -wal and -shm,
	// which must be as private as the database itself.
	_, err = d.Exec(`INSERT INTO agent_log_meta (key, value) VALUES ('perm_probe', 'x')`)
	require.NoError(t, err)
	for _, p := range []string{path, path + "-wal", path + "-shm"} {
		info, err := os.Stat(p)
		require.NoError(t, err, p)
		assert.Equal(t, os.FileMode(0o600), info.Mode().Perm(), p)
	}

	// A second open of the current file runs no migration and still works.
	require.NoError(t, d.Close())
	d2, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d2.Close() })
	var versions int
	require.NoError(t, d2.QueryRow(`SELECT COUNT(*) FROM goose_db_version WHERE version_id > 0`).Scan(&versions))
	assert.Equal(t, 1, versions)
}

// agentlog.db's migrations run on a goose Provider; watchtower.db's on the
// global goose state. Opening one between two fresh watchtower.db opens must
// leave the second one migrating exactly as the first.
func TestOpen_DoesNotTouchGlobalGoose(t *testing.T) {
	applied := func(d *db.DB) []int64 {
		t.Helper()
		rows, err := d.Query(`SELECT version_id FROM goose_db_version WHERE is_applied = 1 AND version_id > 0 ORDER BY version_id`)
		require.NoError(t, err)
		defer rows.Close()
		var out []int64
		for rows.Next() {
			var v int64
			require.NoError(t, rows.Scan(&v))
			out = append(out, v)
		}
		require.NoError(t, rows.Err())
		return out
	}
	dir := t.TempDir()
	first, err := db.Open(filepath.Join(dir, "first", "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = first.Close() })

	al, err := Open(PathFor(filepath.Join(dir, "first", "watchtower.db")))
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })

	second, err := db.Open(filepath.Join(dir, "second", "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = second.Close() })

	want := applied(first)
	require.Greater(t, len(want), 100, "the first watchtower.db migrated fully")
	assert.Equal(t, want, applied(second))
	var hasProjects int
	require.NoError(t, second.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'projects'`).Scan(&hasProjects))
	assert.Equal(t, 1, hasProjects)
	var alTables int
	require.NoError(t, al.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'projects'`).Scan(&alTables))
	assert.Zero(t, alTables, "agentlog.db holds none of watchtower.db's migrations")
}
