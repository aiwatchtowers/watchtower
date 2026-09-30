package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Migration 00086: project targets gain in_review, and every project target
// status transition is recorded with its time and actor (PROJ-06,
// docs/inventory/projects.md).

type historyRow struct {
	from, to, actor, at string
}

func statusHistory(t *testing.T, d *DB, targetID int64) []historyRow {
	t.Helper()
	rows, err := d.Query(`SELECT COALESCE(from_status, ''), to_status, actor, changed_at
		FROM target_status_history WHERE target_id = ? ORDER BY id`, targetID)
	require.NoError(t, err)
	defer rows.Close()
	var out []historyRow
	for rows.Next() {
		var r historyRow
		require.NoError(t, rows.Scan(&r.from, &r.to, &r.actor, &r.at))
		out = append(out, r)
	}
	require.NoError(t, rows.Err())
	return out
}

func transitions(rows []historyRow) [][3]string {
	out := make([][3]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, [3]string{r.from, r.to, r.actor})
	}
	return out
}

func statusActor(t *testing.T, d *DB, id int64) sql.NullString {
	t.Helper()
	var a sql.NullString
	require.NoError(t, d.QueryRow(`SELECT status_actor FROM targets WHERE id = ?`, id).Scan(&a))
	return a
}

// TestProj06_EveryProjectStatusTransitionIsRecorded guards PROJ-06: every
// writer of a project target's status — the agent's Go path, an unclaimed
// (owner) write, a direct SQL write claiming 'owner' as the Desktop does,
// and the rollup trigger — leaves exactly one history row with its time and
// actor, and the claim never outlives its own write.
func TestProj06_EveryProjectStatusTransitionIsRecorded(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	parent := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "feature")
	child := SeedTestProjectTarget(t, d, pid, nullID(parent), "task")

	// Agent: the project MCP path.
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.UpdateTargetStatusAsTx(tx, int(child), "in_progress", ActorAgent)
	}))
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.UpdateTargetStatusAsTx(tx, int(child), "in_review", ActorAgent)
	}))
	// Desktop: a direct write claiming the owner, in the same UPDATE.
	_, err := d.Exec(`UPDATE targets SET status = 'done', status_actor = 'owner' WHERE id = ?`, child)
	require.NoError(t, err)
	// Unclaimed write (the CLI): recorded as the owner.
	require.NoError(t, d.UpdateTargetStatus(int(child), "in_review"))

	assert.Equal(t, [][3]string{
		{"", "todo", "agent"},
		{"todo", "in_progress", "agent"},
		{"in_progress", "in_review", "agent"},
		{"in_review", "done", "owner"},
		{"done", "in_review", "owner"},
	}, transitions(statusHistory(t, d, child)))

	// The rollup: todo -> in_progress (in_review counts as started) -> done
	// -> in_progress, each written by the trigger as 'system'.
	assert.Equal(t, [][3]string{
		{"", "todo", "agent"},
		{"todo", "in_progress", "system"},
		{"in_progress", "done", "system"},
		{"done", "in_progress", "system"},
	}, transitions(statusHistory(t, d, parent)))

	for _, r := range statusHistory(t, d, child) {
		assert.Regexp(t, `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`, r.at, "changed_at is UTC ISO-8601")
	}
	assert.False(t, statusActor(t, d, child).Valid, "the claim is cleared by its own write")
	assert.False(t, statusActor(t, d, parent).Valid)
}

// The rollup's delete and move paths claim 'system' too, and so do the
// daemon's automated status writers (unsnooze).
func TestProj06_RollupDeleteMoveAndUnsnoozeAreRecordedAsSystem(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	a := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "feature a")
	b := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "feature b")
	doneChild := insertBoardChild(t, d, pid, a, "done")
	openChild := insertBoardChild(t, d, pid, a, "todo")
	moved := insertBoardChild(t, d, pid, b, "done")
	require.Equal(t, "done", targetStatus(t, d, b))

	// Delete: a's only open child goes, so a rolls up to done.
	_, err := d.Exec(`DELETE FROM targets WHERE id = ?`, openChild)
	require.NoError(t, err)
	require.Equal(t, "done", targetStatus(t, d, a))
	// Move: a todo child joins b, so b rolls back from done.
	_, err = d.Exec(`UPDATE targets SET parent_id = ?, status = 'todo' WHERE id = ?`, b, doneChild)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, a, moved)
	require.NoError(t, err)

	for _, id := range []int64{a, b} {
		rows := statusHistory(t, d, id)
		require.Greater(t, len(rows), 1, "target %d rolled up", id)
		for _, r := range rows[1:] {
			assert.Equal(t, "system", r.actor, "target %d: %s -> %s", id, r.from, r.to)
		}
	}

	snoozed := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "snoozed")
	_, err = d.Exec(`UPDATE targets SET status = 'snoozed', snooze_until = '2000-01-01T00:00' WHERE id = ?`, snoozed)
	require.NoError(t, err)
	n, err := d.UnsnoozeExpiredTargets()
	require.NoError(t, err)
	require.Equal(t, 1, n)
	last := statusHistory(t, d, snoozed)
	assert.Equal(t, [3]string{"snoozed", "todo", "system"}, transitions(last)[len(last)-1])
}

func TestProj06_NoStatusChangeRecordsNothingAndDropsTheClaim(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	id := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "task")

	_, err := d.Exec(`UPDATE targets SET status = 'todo', status_actor = 'agent' WHERE id = ?`, id)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET text = 'renamed' WHERE id = ?`, id)
	require.NoError(t, err)

	assert.Len(t, statusHistory(t, d, id), 1, "only the creation row")
	assert.False(t, statusActor(t, d, id).Valid, "a claim with no transition is dropped")

	// A later unclaimed write must not inherit the dropped 'agent' claim.
	require.NoError(t, d.UpdateTargetStatus(int(id), "in_progress"))
	assert.Equal(t, [3]string{"todo", "in_progress", "owner"}, transitions(statusHistory(t, d, id))[1])
}

func TestProj06_PersonalTargetsGetNoHistory(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	require.NoError(t, d.UpdateTargetStatus(int(id), "in_progress"))
	_, err = d.Exec(`UPDATE targets SET status = 'done', status_actor = 'owner' WHERE id = ?`, id)
	require.NoError(t, err)

	assert.Empty(t, statusHistory(t, d, id))
	assert.False(t, statusActor(t, d, id).Valid, "a personal target's claim is dropped too")
}

func TestProj06_InReviewOnlyOnProjectTargets(t *testing.T) {
	d := openTestDB(t)
	personal, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	assert.Error(t, d.UpdateTargetStatus(int(personal), "in_review"), "CHECK rejects in_review off a board")

	pid := newTestProject(t, d)
	id := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "task")
	require.NoError(t, d.UpdateTargetStatus(int(id), "in_review"))
	_, err = d.Exec(`UPDATE targets SET project_id = NULL WHERE id = ?`, id)
	assert.Error(t, err, "an in_review target cannot leave its board")

	_, err = d.Exec(`UPDATE targets SET status_actor = 'robot' WHERE id = ?`, id)
	assert.Error(t, err, "status_actor CHECK")
}

func TestProj06_HistoryCascadesWithTheTarget(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	id := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "task")
	require.NoError(t, d.UpdateTargetStatus(int(id), "in_progress"))
	require.NoError(t, d.DeleteProject(pid))

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM target_status_history`).Scan(&n))
	assert.Zero(t, n)
}

func TestGetTargetStatusHistory_OldestFirstAndCapped(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	id := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "task")
	statuses := []string{"in_progress", "in_review", "in_progress", "in_review", "done"}
	for _, s := range statuses {
		require.NoError(t, d.UpdateTargetStatus(int(id), s))
	}

	all, err := d.GetTargetStatusHistory(id, 0)
	require.NoError(t, err)
	require.Len(t, all, 6)
	assert.Equal(t, "", all[0].FromStatus)
	assert.Equal(t, "todo", all[0].ToStatus)
	assert.Equal(t, "done", all[5].ToStatus)

	last2, err := d.GetTargetStatusHistory(id, 2)
	require.NoError(t, err)
	require.Len(t, last2, 2)
	assert.Equal(t, "in_review", last2[0].ToStatus)
	assert.Equal(t, "done", last2[1].ToStatus)

	none, err := d.GetTargetStatusHistory(9999, 0)
	require.NoError(t, err)
	assert.Empty(t, none)
}

func TestProjectBoard_StatusSinceAndInReviewOrder(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	todo := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "a todo")
	review := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "b review")
	blocked := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "c blocked")
	require.NoError(t, d.UpdateTargetStatus(int(review), "in_review"))
	require.NoError(t, d.UpdateTargetStatus(int(blocked), "blocked"))
	_, err := d.Exec(`UPDATE target_status_history SET changed_at = '2026-01-02T03:04:05Z'
		WHERE target_id = ? AND to_status = 'in_review'`, review)
	require.NoError(t, err)

	board, err := d.GetProjectBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 3)
	assert.Equal(t, []int64{review, blocked, todo},
		[]int64{int64(board[0].Target.ID), int64(board[1].Target.ID), int64(board[2].Target.ID)},
		"in_review ranks right after in_progress, before blocked")
	assert.Equal(t, "2026-01-02T03:04:05Z", board[0].StatusSince)
	assert.NotEmpty(t, board[2].StatusSince)
}

func TestStatusToProgress_InReview(t *testing.T) {
	assert.InDelta(t, 0.8, statusToProgress("in_review"), 1e-9)
}
