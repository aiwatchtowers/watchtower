package db

import (
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// rebuiltObjects maps every index, trigger and view attached to the tables
// migration 00143 recreates to its SQL text.
func rebuiltObjects(t *testing.T, d *DB) map[string]string {
	t.Helper()
	rows, err := d.Query(`SELECT type || ':' || name, sql FROM sqlite_master
		WHERE tbl_name IN ('targets','inbox_items','day_plan_items','workbench_target_archive')
		  AND type IN ('index','trigger','view') AND sql IS NOT NULL`)
	require.NoError(t, err)
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var name, sql string
		require.NoError(t, rows.Scan(&name, &sql))
		out[name] = sql
	}
	require.NoError(t, rows.Err())
	return out
}

func TestMigration00143_LinearEnumsDownUp(t *testing.T) {
	d := openTestDB(t)
	before := rebuiltObjects(t, d)
	require.Contains(t, before, "trigger:targets_status_history_ai")
	require.Contains(t, before, "view:workbench_target_archive")

	_, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, source_type, source_id)
		VALUES ('linear work', '2026-10-18', '2026-10-18', 'linear', 'ENG-1'),
		       ('manual work', '2026-10-18', '2026-10-18', 'manual', '')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO target_links (source_target_id, target_target_id, relation) VALUES (2, 1, 'related')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
		VALUES ('ENG-1', '2026-10-18T10:00:00.000Z', 'ENG-1', 'linear_assigned'),
		       ('ENG-2', '2026-10-18T10:00:00.000Z', 'ENG-2', 'linear_comment_mention'),
		       ('PROJ-1', '2026-10-18T10:00:00.000Z', 'PROJ-1', 'jira_assigned')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO situations (title) VALUES ('s')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (1, 1), (1, 3)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO day_plans (user_id, plan_date, generated_at) VALUES ('U1', '2026-10-18', '2026-10-18T08:00:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO day_plan_items (day_plan_id, kind, source_type, source_id, title)
		VALUES (1, 'backlog', 'linear', 'ENG-1', 'a'), (1, 'backlog', 'jira', 'PROJ-1', 'b')`)
	require.NoError(t, err)

	require.NoError(t, goose.DownTo(d.DB, "migrations", 142))

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets WHERE source_type = 'manual'`).Scan(&n))
	assert.Equal(t, 2, n, "a linear target becomes manual on the Down, never deleted")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM target_links`).Scan(&n))
	assert.Equal(t, 1, n, "the cascade child survives the recreation")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM inbox_items`).Scan(&n))
	assert.Equal(t, 1, n, "only the Jira item fits the old CHECK")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM situation_signals`).Scan(&n))
	assert.Equal(t, 1, n, "the deleted Linear item's signal goes with it; the Jira item's stays")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM situation_signals WHERE inbox_item_id = 3`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM day_plan_items`).Scan(&n))
	assert.Equal(t, 1, n)
	_, err = d.Exec(`INSERT INTO day_plan_items (day_plan_id, kind, source_type, title) VALUES (1, 'backlog', 'linear', 'c')`)
	require.Error(t, err, "the old CHECK refuses linear")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	assert.Equal(t, before, rebuiltObjects(t, d), "every index, trigger and the view come back verbatim")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM target_links`).Scan(&n))
	assert.Equal(t, 1, n)
	var fk int
	require.NoError(t, d.QueryRow(`PRAGMA foreign_keys`).Scan(&fk))
	assert.Equal(t, 1, fk, "foreign keys are back on")

	// The recreated triggers fire: a project target writes its status-history
	// row at creation and on a status change.
	pid, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, source_type, project_id)
		VALUES ('board', '2026-10-18', '2026-10-18', 'linear', ?)`, pid)
	require.NoError(t, err)
	tid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET status = 'in_progress' WHERE id = ?`, tid)
	require.NoError(t, err)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM target_status_history WHERE target_id = ?`, tid).Scan(&n))
	assert.Equal(t, 2, n, "targets_status_history_ai and _au fire after the rebuild")
}

// The rebuilt tables keep their AUTOINCREMENT high-water mark: a deleted top
// id is never handed out again, after the Up or after a Down and Up.
func TestMigration00143_KeepsAutoincrementSequence(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, goose.DownTo(d.DB, "migrations", 142))
	_, err := d.Exec(`INSERT INTO day_plans (user_id, plan_date, generated_at) VALUES ('U1', '2026-10-18', '2026-10-18T08:00:00Z')`)
	require.NoError(t, err)

	inserts := map[string]string{
		"targets":        `INSERT INTO targets (text, period_start, period_end) VALUES ('t', '2026-10-18', '2026-10-18')`,
		"inbox_items":    `INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type) VALUES ('C', lower(hex(randomblob(8))), 'U', 'mention')`,
		"day_plan_items": `INSERT INTO day_plan_items (day_plan_id, kind, source_type, title) VALUES (1, 'backlog', 'manual', 'x')`,
	}
	insert := func(table string) int64 {
		res, err := d.Exec(inserts[table])
		require.NoError(t, err, table)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	top := map[string]int64{}
	for table := range inserts {
		insert(table)
		top[table] = insert(table)
		_, err := d.Exec(`DELETE FROM `+table+` WHERE id = ?`, top[table])
		require.NoError(t, err)
	}

	require.NoError(t, goose.Up(d.DB, "migrations"))
	for table := range inserts {
		id := insert(table)
		assert.Greater(t, id, top[table], "%s reused a deleted id after the Up", table)
		top[table] = id
		_, err := d.Exec(`DELETE FROM `+table+` WHERE id = ?`, id)
		require.NoError(t, err)
	}

	require.NoError(t, goose.DownTo(d.DB, "migrations", 142))
	require.NoError(t, goose.Up(d.DB, "migrations"))
	for table := range inserts {
		assert.Greater(t, insert(table), top[table], "%s reused a deleted id after Down and Up", table)
	}
}
