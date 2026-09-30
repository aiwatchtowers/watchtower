package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func countTargetTriggers(t *testing.T, raw *sql.DB) int {
	t.Helper()
	var n int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master
		WHERE type = 'trigger' AND tbl_name = 'targets'`).Scan(&n))
	return n
}

// TestMigration00086_RebuildKeepsRowsChildrenIndexesAndRollup: the table
// rebuild keeps every target and every ON DELETE CASCADE child, recreates
// every index and 00085's rollup triggers, seeds one history row per
// existing project target, and the rollup still works afterwards — with an
// in_review child counting as started.
func TestMigration00086_RebuildKeepsRowsChildrenIndexesAndRollup(t *testing.T) {
	raw := rawDBAt(t, 85)
	_, err := raw.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	require.NoError(t, err)
	ins := func(id int64, parent any, project any, status, updated string) {
		t.Helper()
		_, err := raw.Exec(`INSERT INTO targets (id, text, period_start, period_end, parent_id, project_id, status, updated_at)
			VALUES (?, 't', '2026-09-29', '2026-09-29', ?, ?, ?, ?)`, id, parent, project, status, updated)
		require.NoError(t, err)
	}
	ins(10, nil, 1, "todo", "2026-09-01T10:00:00Z")
	ins(11, 10, 1, "todo", "2026-09-02T10:00:00Z")
	ins(12, 10, 1, "todo", "2026-09-03T10:00:00Z")
	ins(20, nil, nil, "in_progress", "2026-09-04T10:00:00Z")
	_, err = raw.Exec(`INSERT INTO target_links (source_target_id, target_target_id, relation) VALUES (20, 10, 'related')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO project_comments (project_id, target_id, author, body) VALUES (1, 11, 'owner', 'hi')`)
	require.NoError(t, err)
	indexesBefore := targetIndexes(t, raw)
	require.Equal(t, 3, countTargetTriggers(t, raw))

	require.NoError(t, goose.UpTo(raw, "migrations", 86))

	var n int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM targets`).Scan(&n))
	assert.Equal(t, 4, n)
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM target_links`).Scan(&n))
	assert.Equal(t, 1, n, "a cascade child survives the rebuild")
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM project_comments`).Scan(&n))
	assert.Equal(t, 1, n)
	assert.Equal(t, indexesBefore, targetIndexes(t, raw), "every index is recreated")
	assert.Equal(t, 6, countTargetTriggers(t, raw), "3 rollup + 2 history + 1 actor reset")

	rows, err := raw.Query(`SELECT target_id, COALESCE(from_status,'-'), to_status, changed_at, actor
		FROM target_status_history ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var seeded [][5]string
	for rows.Next() {
		var r [5]string
		require.NoError(t, rows.Scan(&r[0], &r[1], &r[2], &r[3], &r[4]))
		seeded = append(seeded, r)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, [][5]string{
		{"10", "-", "todo", "2026-09-01T10:00:00Z", "system"},
		{"11", "-", "todo", "2026-09-02T10:00:00Z", "system"},
		{"12", "-", "todo", "2026-09-03T10:00:00Z", "system"},
	}, seeded, "one seed row per project target, none for the personal one")

	// The rollup survives the rebuild and treats in_review as started.
	_, err = raw.Exec(`UPDATE targets SET status = 'in_review' WHERE id = 11`)
	require.NoError(t, err)
	var st string
	require.NoError(t, raw.QueryRow(`SELECT status FROM targets WHERE id = 10`).Scan(&st))
	assert.Equal(t, "in_progress", st)
	_, err = raw.Exec(`UPDATE targets SET status = 'done' WHERE id IN (11, 12)`)
	require.NoError(t, err)
	require.NoError(t, raw.QueryRow(`SELECT status FROM targets WHERE id = 10`).Scan(&st))
	assert.Equal(t, "done", st, "all children closed -> done (PROJ-05 unchanged)")
}

// TestMigration00086_DownRestoresThe00085Schema: Down is real — in_review
// falls back to in_progress, the history and actor column go, 00085's
// triggers are back, and a re-Up restores everything.
func TestMigration00086_DownRestoresThe00085Schema(t *testing.T) {
	raw := rawDBAt(t, 86)
	_, err := raw.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO targets (id, text, period_start, period_end, project_id, status)
		VALUES (5, 't', '2026-09-29', '2026-09-29', 1, 'in_review')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO target_links (source_target_id, external_ref, relation) VALUES (5, 'jira:X-1', 'related')`)
	require.NoError(t, err)

	require.NoError(t, goose.DownTo(raw, "migrations", 85))
	var st string
	require.NoError(t, raw.QueryRow(`SELECT status FROM targets WHERE id = 5`).Scan(&st))
	assert.Equal(t, "in_progress", st)
	assert.False(t, columnNames(t, raw, "targets")["status_actor"])
	var n int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'target_status_history'`).Scan(&n))
	assert.Zero(t, n)
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM target_links`).Scan(&n))
	assert.Equal(t, 1, n)
	assert.Equal(t, 3, countTargetTriggers(t, raw))
	_, err = raw.Exec(`UPDATE targets SET status = 'in_review' WHERE id = 5`)
	assert.Error(t, err, "the 00085 CHECK has no in_review")

	require.NoError(t, goose.UpTo(raw, "migrations", 86))
	assert.Equal(t, 6, countTargetTriggers(t, raw))
}

func targetIndexes(t *testing.T, raw *sql.DB) []string {
	t.Helper()
	rows, err := raw.Query(`SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'targets'
		AND name NOT LIKE 'sqlite_autoindex%' ORDER BY name`)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(t, rows.Err())
	return out
}

func TestProj06_SameHistoryWithRecursiveTriggersOn(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`PRAGMA recursive_triggers = ON`)
	require.NoError(t, err)
	pid := newTestProject(t, d)
	parent := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "feature")
	child := SeedTestProjectTarget(t, d, pid, nullID(parent), "task")
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.UpdateTargetStatusAsTx(tx, int(child), "in_review", ActorAgent)
	}))

	assert.Equal(t, [][3]string{{"", "todo", "agent"}, {"todo", "in_review", "agent"}},
		transitions(statusHistory(t, d, child)))
	assert.Equal(t, [][3]string{{"", "todo", "agent"}, {"todo", "in_progress", "system"}},
		transitions(statusHistory(t, d, parent)))
	assert.False(t, statusActor(t, d, child).Valid)
}
