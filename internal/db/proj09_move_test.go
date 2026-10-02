package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// PROJ-09 (board #186): a workbench target moves under another target of its
// workbench or to the top level, never into a cycle or across workbenches,
// and both parents re-derive their status (PROJ-05) and progress.

func moveTarget(t *testing.T, d *DB, projectID, id int64, parent sql.NullInt64) error {
	t.Helper()
	return d.WithTx(func(tx *sql.Tx) error { return d.MoveWorkbenchTargetTx(tx, projectID, id, parent) })
}

func targetParent(t *testing.T, d *DB, id int64) sql.NullInt64 {
	t.Helper()
	var p sql.NullInt64
	require.NoError(t, d.QueryRow(`SELECT parent_id FROM targets WHERE id = ?`, id).Scan(&p))
	return p
}

func targetProgress(t *testing.T, d *DB, id int64) float64 {
	t.Helper()
	var p float64
	require.NoError(t, d.QueryRow(`SELECT progress FROM targets WHERE id = ?`, id).Scan(&p))
	return p
}

func TestProj09_MoveReRollsBothParentsStatusAndProgress(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	from := insertWorkbenchTargetRow(t, d, pid, "from")
	to := insertWorkbenchTargetRow(t, d, pid, "to")
	moving := insertBoardChild(t, d, pid, from, "in_progress")
	stays := insertBoardChild(t, d, pid, from, "done")
	insertBoardChild(t, d, pid, to, "todo")
	require.NoError(t, d.SetTargetProgress(int(moving), 0.5))
	require.NoError(t, d.SetTargetProgress(int(stays), 1))
	require.Equal(t, "in_progress", targetStatus(t, d, from))
	require.Equal(t, "todo", targetStatus(t, d, to))

	require.NoError(t, moveTarget(t, d, pid, moving, nullID(to)))

	assert.Equal(t, nullID(to), targetParent(t, d, moving))
	assert.Equal(t, "done", targetStatus(t, d, from), "the old parent keeps only its done child")
	assert.Equal(t, "in_progress", targetStatus(t, d, to), "the new parent gains a started child")
	assert.InDelta(t, 1.0, targetProgress(t, d, from), 1e-9)
	assert.InDelta(t, 0.25, targetProgress(t, d, to), 1e-9, "avg of 0 and 0.5")

	var actor string
	require.NoError(t, d.QueryRow(`SELECT actor FROM target_status_history WHERE target_id = ? ORDER BY id DESC LIMIT 1`,
		to).Scan(&actor))
	assert.Equal(t, ActorSystem, actor, "a rollup the move caused is the system's")
}

func TestProj09_MoveToTheTopLevel(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	parent := insertWorkbenchTargetRow(t, d, pid, "parent")
	insertBoardChild(t, d, pid, parent, "blocked")
	child := insertBoardChild(t, d, pid, parent, "todo")
	require.Equal(t, "todo", targetStatus(t, d, parent))

	require.NoError(t, moveTarget(t, d, pid, child, sql.NullInt64{}))

	assert.False(t, targetParent(t, d, child).Valid)
	assert.Equal(t, "blocked", targetStatus(t, d, parent), "every open child left is blocked")
}

func TestProj09_MoveRefusesACycle(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	root := insertWorkbenchTargetRow(t, d, pid, "root")
	mid := insertBoardChild(t, d, pid, root, "todo")
	leaf := insertBoardChild(t, d, pid, mid, "todo")

	for name, parent := range map[string]int64{"itself": root, "its child": mid, "its grandchild": leaf} {
		err := moveTarget(t, d, pid, root, nullID(parent))
		require.ErrorIs(t, err, ErrParentCycle, name)
		assert.False(t, targetParent(t, d, root).Valid, "%s: nothing written", name)
	}
	// A sibling subtree is fine: mid moves to the top level, root under it.
	require.NoError(t, moveTarget(t, d, pid, mid, sql.NullInt64{}))
	require.NoError(t, moveTarget(t, d, pid, root, nullID(leaf)))
	assert.Equal(t, nullID(leaf), targetParent(t, d, root))
}

func TestProj09_MoveRefusesAnotherBoard(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	mine := insertWorkbenchTargetRow(t, d, pid, "mine")
	theirs := insertWorkbenchTargetRow(t, d, other, "theirs")
	personal, err := d.CreateTarget(Target{Text: "personal", Level: "day", Status: "todo",
		Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	cases := []struct {
		name       string
		id, parent int64
	}{
		{"parent on another workbench", mine, theirs},
		{"personal parent", mine, personal},
		{"missing parent", mine, 99999},
		{"target of another workbench", theirs, mine},
		{"personal target", personal, mine},
		{"missing target", 99999, mine},
	}
	for _, c := range cases {
		err := moveTarget(t, d, pid, c.id, nullID(c.parent))
		require.ErrorIs(t, err, ErrNotInWorkbench, c.name)
	}
	assert.False(t, targetParent(t, d, mine).Valid)
	assert.False(t, targetParent(t, d, theirs).Valid)
	require.ErrorIs(t, moveTarget(t, d, pid, theirs, sql.NullInt64{}), ErrNotInWorkbench, "nor to the top level")
}

func TestProj09_UnchangedParentWritesNothing(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	parent := insertWorkbenchTargetRow(t, d, pid, "parent")
	child := insertBoardChild(t, d, pid, parent, "todo")
	_, err := d.Exec(`UPDATE targets SET updated_at = '2020-01-01T00:00:00Z' WHERE id = ?`, child)
	require.NoError(t, err)

	require.NoError(t, moveTarget(t, d, pid, child, nullID(parent)))

	var updated string
	require.NoError(t, d.QueryRow(`SELECT updated_at FROM targets WHERE id = ?`, child).Scan(&updated))
	assert.Equal(t, "2020-01-01T00:00:00Z", updated)
}

// The generic `targets update --parent` path (db.UpdateTarget) refuses a
// cycle too, but a row already in one stays editable.
func TestProj09_UpdateTargetRefusesACycle(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	root := insertWorkbenchTargetRow(t, d, pid, "root")
	child := insertBoardChild(t, d, pid, root, "todo")

	got, err := d.GetTargetByID(int(root))
	require.NoError(t, err)
	got.ParentID = nullID(child)
	require.ErrorIs(t, d.UpdateTarget(*got), ErrParentCycle)

	_, err = d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, child, root)
	require.NoError(t, err)
	got, err = d.GetTargetByID(int(root))
	require.NoError(t, err)
	got.Text = "renamed"
	require.NoError(t, d.UpdateTarget(*got), "an unchanged parent is not re-checked")
}

// The ancestor walk ends on a row already in a cycle (UNION by id): a move
// under a member of an existing cycle is answered, not hung.
func TestProj09_CycleCheckEndsOnAnExistingCycle(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	a := insertWorkbenchTargetRow(t, d, pid, "a")
	b := insertBoardChild(t, d, pid, a, "todo")
	_, err := d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, b, a)
	require.NoError(t, err)
	x := insertWorkbenchTargetRow(t, d, pid, "x")

	require.NoError(t, d.CheckParentCycle(x, nullID(a)))
	require.ErrorIs(t, d.CheckParentCycle(a, nullID(b)), ErrParentCycle)
}
