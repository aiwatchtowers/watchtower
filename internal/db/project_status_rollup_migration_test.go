package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00085_RecomputesExistingBoards: an install whose boards were
// written before the rollup existed gets every project parent re-derived
// once, deepest first, and personal targets stay as they were.
func TestMigration00085_RecomputesExistingBoards(t *testing.T) {
	raw := rawDBAt(t, 82)
	_, err := raw.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme'), (2, 'other', '/tmp/other')`)
	require.NoError(t, err)
	ins := func(id int64, parent any, project any, status string) {
		t.Helper()
		_, err := raw.Exec(`INSERT INTO targets (id, text, period_start, period_end, parent_id, project_id, status)
			VALUES (?, 't', '2026-09-29', '2026-09-29', ?, ?, ?)`, id, parent, project, status)
		require.NoError(t, err)
	}
	// Root first, then deeper levels: a parent-first order would compute the
	// root from its child's stale status, so this pins the deepest-first order.
	ins(10, nil, 1, "todo")     // root: {20 -> done, 21 done} -> done
	ins(20, 10, 1, "todo")      // mid: {30 done, 31 dismissed} -> done
	ins(21, 10, 1, "done")      //
	ins(30, 20, 1, "done")      //
	ins(31, 20, 1, "dismissed") //
	ins(40, nil, 1, "done")     // no children: untouched
	ins(50, nil, nil, "todo")   // personal parent: untouched
	ins(51, 50, nil, "done")    //
	ins(60, nil, 1, "todo")     // {blocked, done} -> blocked
	ins(61, 60, 1, "blocked")   //
	ins(62, 60, 1, "done")      //
	ins(70, nil, 1, "done")     // {todo, done} -> in_progress
	ins(71, 70, 1, "todo")      //
	ins(72, 70, 1, "done")      //
	ins(80, nil, 1, "blocked")  // {todo, snoozed} -> todo
	ins(81, 80, 1, "todo")      //
	ins(82, 80, 1, "snoozed")   //
	ins(90, nil, 1, "todo")     // {todo} + another project's done child -> todo, unwritten
	ins(91, 90, 1, "todo")      //
	ins(92, 90, 2, "done")      //

	_, err = raw.Exec(`UPDATE targets SET updated_at = '2000-01-01T00:00:00Z'`)
	require.NoError(t, err)

	require.NoError(t, goose.Up(raw, "migrations"))

	status := func(id int64) string {
		var s string
		require.NoError(t, raw.QueryRow(`SELECT status FROM targets WHERE id = ?`, id).Scan(&s))
		return s
	}
	assert.Equal(t, "done", status(20))
	assert.Equal(t, "done", status(10), "the root is computed from its already-recomputed child")
	assert.Equal(t, "done", status(40))
	assert.Equal(t, "todo", status(50), "a personal target is never rolled up")
	assert.Equal(t, "blocked", status(60))
	assert.Equal(t, "in_progress", status(70))
	assert.Equal(t, "todo", status(80))
	assert.Equal(t, "todo", status(90), "another project's child is not counted")
	var updated string
	require.NoError(t, raw.QueryRow(`SELECT updated_at FROM targets WHERE id = 90`).Scan(&updated))
	assert.Equal(t, "2000-01-01T00:00:00Z", updated, "an already-correct parent is not written")

	var n int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'project_status_rollup_seed%'`).Scan(&n))
	assert.Zero(t, n, "the seed helper is dropped")
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master
		WHERE type = 'trigger' AND name LIKE 'targets_project_status_rollup_%'`).Scan(&n))
	assert.Equal(t, 3, n)
}

// TestMigration00085_DownDropsTheTriggers: Down is real, and re-Up restores.
func TestMigration00085_DownDropsTheTriggers(t *testing.T) {
	raw := rawDBAt(t, 85)
	countTriggers := func(db *sql.DB) int {
		var n int
		require.NoError(t, db.QueryRow(`SELECT COUNT(*) FROM sqlite_master
			WHERE type = 'trigger' AND name LIKE 'targets_project_status_rollup_%'`).Scan(&n))
		return n
	}
	require.Equal(t, 3, countTriggers(raw))
	require.NoError(t, goose.DownTo(raw, "migrations", 82))
	assert.Zero(t, countTriggers(raw))
	require.NoError(t, goose.UpTo(raw, "migrations", 85))
	assert.Equal(t, 3, countTriggers(raw))
}
