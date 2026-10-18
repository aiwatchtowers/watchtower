package db

import (
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// schemaObjects counts the triggers, indexes and views attached to the
// tables migration 00143 recreates.
func schemaObjects(t *testing.T, d *DB) map[string]int {
	t.Helper()
	rows, err := d.Query(`SELECT type, COUNT(*) FROM sqlite_master
		WHERE tbl_name IN ('targets','inbox_items','day_plan_items','workbench_target_archive')
		GROUP BY type`)
	require.NoError(t, err)
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var typ string
		var n int
		require.NoError(t, rows.Scan(&typ, &n))
		out[typ] = n
	}
	require.NoError(t, rows.Err())
	return out
}

func TestMigration00143_LinearEnumsDownUp(t *testing.T) {
	d := openTestDB(t)
	before := schemaObjects(t, d)
	require.Positive(t, before["trigger"])

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
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM day_plan_items`).Scan(&n))
	assert.Equal(t, 1, n)
	_, err = d.Exec(`INSERT INTO day_plan_items (day_plan_id, kind, source_type, title) VALUES (1, 'backlog', 'linear', 'c')`)
	require.Error(t, err, "the old CHECK refuses linear")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	assert.Equal(t, before, schemaObjects(t, d), "every index, trigger and the view come back")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM target_links`).Scan(&n))
	assert.Equal(t, 1, n)
	// The recreated triggers still fire: a project target's status history row.
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, source_type) VALUES ('x', '2026-10-18', '2026-10-18', 'linear')`)
	require.NoError(t, err)
	var fk int
	require.NoError(t, d.QueryRow(`PRAGMA foreign_keys`).Scan(&fk))
	assert.Equal(t, 1, fk, "foreign keys are back on")
}
