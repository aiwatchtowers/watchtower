package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// automationRunObjects maps every index and trigger attached to
// automation_runs to its SQL text.
func automationRunObjects(t *testing.T, d *DB) map[string]string {
	t.Helper()
	rows, err := d.Query(`SELECT type || ':' || name, sql FROM sqlite_master
		WHERE tbl_name = 'automation_runs' AND type IN ('index','trigger') AND sql IS NOT NULL`)
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

func countWhere(t *testing.T, d *DB, q string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(q, args...).Scan(&n), q)
	return n
}

func runsSeq(t *testing.T, d *DB) int64 {
	t.Helper()
	var seq int64
	require.NoError(t, d.QueryRow(`SELECT seq FROM sqlite_sequence WHERE name = 'automation_runs'`).Scan(&seq))
	return seq
}

func TestMigration00147_BackfillsDoneAtFromReadAt(t *testing.T) {
	d := openTestDB(t)
	objectsAtHead := automationRunObjects(t, d)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 146))
	before := automationRunObjects(t, d)

	wb := newTestWorkbench(t, d)
	a := seedAutomationRow(t, d, "digest", "/acme/automations/digest.md", "h1")
	_, err := d.Exec(`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES
		(1, ?, 'manual', 'succeeded'), (2, ?, 'schedule', 'waiting'), (3, ?, 'manual', 'queued')`, a, a, a)
	require.NoError(t, err)
	// A deleted top id: the carried sequence must never hand it out again.
	_, err = d.Exec(`DELETE FROM automation_runs WHERE id = 3`)
	require.NoError(t, err)
	seq := runsSeq(t, d)
	require.Equal(t, int64(3), seq)
	_, err = d.Exec(`INSERT INTO automation_run_steps (run_id, seq, kind, status) VALUES (2, 1, 'ask', 'waiting')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_run_replay (run_id, seq, kind, name, args_hash, pending) VALUES (2, 1, 'ask', 'question', 'a1', 1)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO owner_asks (project_id, kind, title, automation_run_id) VALUES (?, 'question', 'Q', 2)`, wb)
	require.NoError(t, err)
	sid := newTestSession(t, d, wb)
	_, err = d.Exec(`UPDATE terminal_sessions SET automation_run_id = 2 WHERE id = ?`, sid)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, read_at, dismissed_at) VALUES
		(1, ?, 1, 'inbox', 'read', 'b', '2026-10-20T09:00:00Z', NULL),
		(2, ?, 1, 'inbox', 'unread', 'b', NULL, NULL),
		(3, ?, 1, 'inbox', 'dismissed', 'b', NULL, '2026-10-20T10:00:00Z')`, a, a, a)
	require.NoError(t, err)

	require.NoError(t, gooseUp(d.DB, "migrations"))

	var done *string
	require.NoError(t, d.QueryRow(`SELECT done_at FROM automation_outputs WHERE id = 1`).Scan(&done))
	require.NotNil(t, done)
	assert.Equal(t, "2026-10-20T09:00:00Z", *done, "a read card is done")
	assert.Equal(t, 2, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs WHERE id IN (2, 3) AND done_at IS NULL`))
	assert.Equal(t, 3, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs WHERE link = '' AND actions_json = '[]'
		AND pressed_action IS NULL AND pressed_run_id IS NULL AND pressed_at IS NULL`))
	assert.Equal(t, 2, countWhere(t, d, `SELECT COUNT(*) FROM automation_runs`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_steps WHERE run_id = 2`), "the step survives")
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_replay WHERE run_id = 2`), "the replay row survives")
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM owner_asks WHERE automation_run_id = 2`), "the ask link survives")
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM terminal_sessions WHERE automation_run_id = 2`), "the session link survives")
	assert.Equal(t, seq, runsSeq(t, d), "the AUTOINCREMENT high-water mark is carried")
	assert.Equal(t, 1, countWhere(t, d, `PRAGMA foreign_keys`), "foreign keys are back on")
	assert.Equal(t, objectsAtHead, automationRunObjects(t, d), "every index and the trigger are recreated")

	_, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger, event_json) VALUES (?, 'reply', '{}'), (?, 'reply', '{}')`, a, a)
	require.NoError(t, err, "two queued reply runs fit the CHECK and the partial unique index")
	_, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger) VALUES (?, 'bogus')`, a)
	require.Error(t, err, "the CHECK still refuses an unknown trigger")
	_, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger) VALUES (?, 'manual'), (?, 'manual')`, a, a)
	require.Error(t, err, "two queued manual runs still collide")
	_, err = d.Exec(`INSERT INTO automation_run_steps (run_id, seq, kind, status) VALUES (4, 1, 'state', 'ok')`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE automation_outputs SET pressed_run_id = 4, done_at = NULL, read_at = NULL WHERE id = 1`)
	require.NoError(t, err)

	// Down: the reply runs and their children go, everything else stays; a
	// done card that was never read reads as read.
	_, err = d.Exec(`UPDATE automation_outputs SET done_at = '2026-10-20T11:00:00Z' WHERE id = 2`)
	require.NoError(t, err)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 146))
	assert.Equal(t, before, automationRunObjects(t, d), "the 00146 indexes and trigger come back verbatim")
	assert.Equal(t, 2, countWhere(t, d, `SELECT COUNT(*) FROM automation_runs`))
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_steps WHERE run_id = 4`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_replay WHERE run_id = 2`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM owner_asks WHERE automation_run_id = 2`))
	assert.Equal(t, 3, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs WHERE id = 2 AND read_at = '2026-10-20T11:00:00Z'`))
	assert.False(t, columnNames(t, d.DB, "automation_outputs")["done_at"])
	assert.Equal(t, 1, countWhere(t, d, `PRAGMA foreign_keys`))
	_, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger) VALUES (?, 'reply')`, a)
	require.Error(t, err, "the old CHECK refuses reply")

	// Up again is clean, and the replay cleanup trigger still fires.
	require.NoError(t, gooseUp(d.DB, "migrations"))
	assert.Equal(t, objectsAtHead, automationRunObjects(t, d))
	_, err = d.Exec(`UPDATE automation_runs SET status = 'failed' WHERE id = 2`)
	require.NoError(t, err)
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_replay WHERE run_id = 2`),
		"automation_runs_replay_cleanup fires after the rebuild")
}
