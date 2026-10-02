package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Migration 00085's triggers: a project parent's status follows its
// children (PROJ-05, docs/inventory/workbench.md).

// insertBoardChild plants a project target under parent with a given status.
func insertBoardChild(t *testing.T, d *DB, projectID, parentID int64, status string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end,
			source_type, project_id, parent_id, status)
		VALUES ('child', 'custom', 'project', '2026-09-29', '2026-09-29', 'chat', ?, ?, ?)`,
		projectID, parentID, status)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func targetStatus(t *testing.T, d *DB, id int64) string {
	t.Helper()
	var s string
	require.NoError(t, d.QueryRow(`SELECT status FROM targets WHERE id = ?`, id).Scan(&s))
	return s
}

func setStatusRaw(t *testing.T, d *DB, id int64, status string) {
	t.Helper()
	_, err := d.Exec(`UPDATE targets SET status = ? WHERE id = ?`, status, id)
	require.NoError(t, err)
}

// TestProj05_ProjectParentStatusFollowsChildren guards PROJ-05: every rule
// of the rollup, over direct children.
func TestProj05_ProjectParentStatusFollowsChildren(t *testing.T) {
	cases := []struct {
		name     string
		children []string
		want     string
	}{
		{"all todo", []string{"todo", "todo"}, "todo"},
		{"one in progress", []string{"todo", "in_progress"}, "in_progress"},
		{"one done, not all closed", []string{"todo", "done"}, "in_progress"},
		{"all done", []string{"done", "done"}, "done"},
		{"done and dismissed", []string{"done", "dismissed"}, "done"},
		{"all dismissed", []string{"dismissed", "dismissed"}, "dismissed"},
		{"every open child blocked", []string{"blocked", "done", "blocked"}, "blocked"},
		{"one blocked, one todo", []string{"blocked", "todo"}, "todo"},
		{"one blocked, one in progress", []string{"blocked", "in_progress"}, "in_progress"},
		{"snoozed counts as open, not started", []string{"snoozed", "todo"}, "todo"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := openTestDB(t)
			pid := newTestWorkbench(t, d)
			parent := insertWorkbenchTargetRow(t, d, pid, "feature")
			for _, s := range tc.children {
				insertBoardChild(t, d, pid, parent, s)
			}
			assert.Equal(t, tc.want, targetStatus(t, d, parent))
		})
	}
}

func TestProj05_ChildStatusChangeRollsUpThroughGoWriter(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	parent := insertWorkbenchTargetRow(t, d, pid, "feature")
	a := insertBoardChild(t, d, pid, parent, "todo")
	b := insertBoardChild(t, d, pid, parent, "todo")
	assert.Equal(t, "todo", targetStatus(t, d, parent))

	require.NoError(t, d.UpdateTargetStatus(int(a), "in_progress"))
	assert.Equal(t, "in_progress", targetStatus(t, d, parent))

	require.NoError(t, d.UpdateTargetStatus(int(a), "done"))
	require.NoError(t, d.UpdateTargetStatus(int(b), "done"))
	assert.Equal(t, "done", targetStatus(t, d, parent))

	// The Go progress walk runs after the trigger and agrees with it.
	got, err := d.GetTargetByID(int(parent))
	require.NoError(t, err)
	assert.InDelta(t, 1.0, got.Progress, 1e-9)

	require.NoError(t, d.UpdateTargetStatus(int(b), "todo"))
	assert.Equal(t, "in_progress", targetStatus(t, d, parent), "reopening a child reopens the parent")
}

func TestProj05_MultiLevelChainRollsUp(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	root := insertWorkbenchTargetRow(t, d, pid, "plan")
	mid := insertBoardChild(t, d, pid, root, "todo")
	leaf1 := insertBoardChild(t, d, pid, mid, "todo")
	leaf2 := insertBoardChild(t, d, pid, mid, "todo")
	other := insertBoardChild(t, d, pid, root, "done")
	_ = other
	// root: {mid todo, other done} -> in_progress.
	assert.Equal(t, "in_progress", targetStatus(t, d, root))

	setStatusRaw(t, d, leaf1, "done")
	assert.Equal(t, "in_progress", targetStatus(t, d, mid))
	setStatusRaw(t, d, leaf2, "done")
	assert.Equal(t, "done", targetStatus(t, d, mid), "all leaves closed")
	assert.Equal(t, "done", targetStatus(t, d, root), "the change reaches the root")

	setStatusRaw(t, d, leaf2, "blocked")
	assert.Equal(t, "blocked", targetStatus(t, d, mid))
	assert.Equal(t, "blocked", targetStatus(t, d, root), "only open child of root is blocked")
}

func TestProj05_DeepChainWithParentIDsAboveChildren(t *testing.T) {
	// Parents created after their children (ids ascending upward) must roll
	// up the same way: the walk does not depend on row order.
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	leaf := insertWorkbenchTargetRow(t, d, pid, "leaf")
	chain := []int64{leaf}
	for i := 0; i < 6; i++ {
		p := insertWorkbenchTargetRow(t, d, pid, "level")
		_, err := d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, p, chain[len(chain)-1])
		require.NoError(t, err)
		chain = append(chain, p)
	}
	setStatusRaw(t, d, leaf, "done")
	for _, id := range chain {
		assert.Equal(t, "done", targetStatus(t, d, id), "target %d", id)
	}
}

func TestProj05_ExplicitParentStatusStandsUntilAChildChanges(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	root := insertWorkbenchTargetRow(t, d, pid, "plan")
	parent := insertBoardChild(t, d, pid, root, "todo")
	a := insertBoardChild(t, d, pid, parent, "todo")
	insertBoardChild(t, d, pid, parent, "todo")

	require.NoError(t, d.UpdateTargetStatus(int(parent), "blocked"))
	assert.Equal(t, "blocked", targetStatus(t, d, parent), "the parent's own update is never rolled up")

	// An unrelated edit of a child (no status/parent change) leaves it alone.
	_, err := d.Exec(`UPDATE targets SET text = 'renamed', status = status WHERE id = ?`, a)
	require.NoError(t, err)
	assert.Equal(t, "blocked", targetStatus(t, d, parent))

	setStatusRaw(t, d, a, "in_progress")
	assert.Equal(t, "in_progress", targetStatus(t, d, parent), "a child change re-derives it")
}

func TestProj05_AncestorOverrideSurvivesWhenIntermediateStatusUnchanged(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	root := insertWorkbenchTargetRow(t, d, pid, "plan")
	mid := insertBoardChild(t, d, pid, root, "todo")
	a := insertBoardChild(t, d, pid, mid, "in_progress")
	b := insertBoardChild(t, d, pid, mid, "todo")
	require.Equal(t, "in_progress", targetStatus(t, d, mid))
	require.Equal(t, "in_progress", targetStatus(t, d, root))

	setStatusRaw(t, d, root, "blocked") // explicit override on the root
	setStatusRaw(t, d, b, "in_progress")
	assert.Equal(t, "in_progress", targetStatus(t, d, mid))
	assert.Equal(t, "blocked", targetStatus(t, d, root),
		"mid did not change, so none of the root's children changed")
	_ = a
}

func TestProj05_InsertDeleteAndMoveRollUp(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	p1 := insertWorkbenchTargetRow(t, d, pid, "one")
	p2 := insertWorkbenchTargetRow(t, d, pid, "two")
	done := insertBoardChild(t, d, pid, p1, "done")
	assert.Equal(t, "done", targetStatus(t, d, p1))

	open := insertBoardChild(t, d, pid, p1, "todo")
	assert.Equal(t, "in_progress", targetStatus(t, d, p1), "an inserted open child reopens the parent")

	require.NoError(t, d.DeleteTarget(int(open)))
	assert.Equal(t, "done", targetStatus(t, d, p1), "deleting the open child re-rolls the parent")

	insertBoardChild(t, d, pid, p2, "todo")
	_, err := d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, p2, done)
	require.NoError(t, err)
	assert.Equal(t, "in_progress", targetStatus(t, d, p2), "the new parent sees the moved child")
	// p1 lost its last child: no children -> untouched.
	assert.Equal(t, "done", targetStatus(t, d, p1))
}

func TestProj05_MoveBetweenSiblingsRecomputesSharedAncestor(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	root := insertWorkbenchTargetRow(t, d, pid, "plan")
	a := insertBoardChild(t, d, pid, root, "todo")
	b := insertBoardChild(t, d, pid, root, "todo")
	x := insertBoardChild(t, d, pid, a, "blocked")
	insertBoardChild(t, d, pid, b, "done")
	insertBoardChild(t, d, pid, b, "todo")
	require.Equal(t, "blocked", targetStatus(t, d, a))
	require.Equal(t, "in_progress", targetStatus(t, d, b))
	require.Equal(t, "in_progress", targetStatus(t, d, root))

	// x moves from a to b: a has no children left (untouched, stays blocked),
	// b = {done, todo, blocked} -> in_progress; root recomputed from both.
	_, err := d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, b, x)
	require.NoError(t, err)
	assert.Equal(t, "blocked", targetStatus(t, d, a))
	assert.Equal(t, "in_progress", targetStatus(t, d, b))
	assert.Equal(t, "in_progress", targetStatus(t, d, root))
}

func TestProj05_NonProjectTargetsAreNeverRolledUp(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, status)
		VALUES ('personal', '2026-09-29', '2026-09-29', 'todo')`)
	require.NoError(t, err)
	parent, _ := res.LastInsertId()
	res, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, parent_id, status)
		VALUES ('sub', '2026-09-29', '2026-09-29', ?, 'done')`, parent)
	require.NoError(t, err)
	child, _ := res.LastInsertId()
	setStatusRaw(t, d, child, "in_progress")
	setStatusRaw(t, d, child, "done")
	assert.Equal(t, "todo", targetStatus(t, d, parent))
}

func TestProj05_OtherProjectRowsAreNeverTouched(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	parent := insertWorkbenchTargetRow(t, d, pid, "feature")
	foreign := insertWorkbenchTargetRow(t, d, other, "other board")
	// A child of the other project wired under our parent (never produced
	// by the tools) is neither counted nor does it write across projects.
	_, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, parent_id, status)
		VALUES ('stray', '2026-09-29', '2026-09-29', ?, ?, 'done')`, other, parent)
	require.NoError(t, err)
	assert.Equal(t, "todo", targetStatus(t, d, parent), "a foreign-project child is not counted")

	// Our child under the other project's target never writes it.
	insertBoardChild(t, d, pid, foreign, "done")
	assert.Equal(t, "todo", targetStatus(t, d, foreign))
}

func TestProj05_UpdatedAtMovesOnlyWithARealStatusChange(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	parent := insertWorkbenchTargetRow(t, d, pid, "feature")
	a := insertBoardChild(t, d, pid, parent, "in_progress")
	b := insertBoardChild(t, d, pid, parent, "todo")
	require.Equal(t, "in_progress", targetStatus(t, d, parent))

	_, err := d.Exec(`UPDATE targets SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?`, parent)
	require.NoError(t, err)
	setStatusRaw(t, d, b, "blocked") // {in_progress, blocked} -> still in_progress
	var updated string
	require.NoError(t, d.QueryRow(`SELECT updated_at FROM targets WHERE id = ?`, parent).Scan(&updated))
	assert.Equal(t, "2000-01-01T00:00:00Z", updated, "no status change, no updated_at bump")

	setStatusRaw(t, d, a, "done") // {done, blocked} -> blocked
	require.NoError(t, d.QueryRow(`SELECT updated_at FROM targets WHERE id = ?`, parent).Scan(&updated))
	assert.NotEqual(t, "2000-01-01T00:00:00Z", updated)
}

func TestProj05_SameResultWithRecursiveTriggersOn(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`PRAGMA recursive_triggers = ON`)
	require.NoError(t, err)
	var on int
	require.NoError(t, d.QueryRow(`PRAGMA recursive_triggers`).Scan(&on))
	require.Equal(t, 1, on, "the pragma is on for the connection the writes use")
	pid := newTestWorkbench(t, d)
	root := insertWorkbenchTargetRow(t, d, pid, "plan")
	mid := insertBoardChild(t, d, pid, root, "todo")
	leaf := insertBoardChild(t, d, pid, mid, "todo")
	insertBoardChild(t, d, pid, root, "todo")
	setStatusRaw(t, d, leaf, "done")
	assert.Equal(t, "done", targetStatus(t, d, mid))
	assert.Equal(t, "in_progress", targetStatus(t, d, root))
}

func TestProj05_DeleteProjectWithMultiLevelBoardLeavesNoRows(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	keep := newTestWorkbench(t, d)
	root := insertWorkbenchTargetRow(t, d, pid, "plan")
	for i := 0; i < 3; i++ {
		mid := insertBoardChild(t, d, pid, root, "in_progress")
		for j := 0; j < 3; j++ {
			leaf := insertBoardChild(t, d, pid, mid, "todo")
			insertBoardChild(t, d, pid, leaf, "done")
		}
	}
	keepRoot := insertWorkbenchTargetRow(t, d, keep, "other plan")
	keepChild := insertBoardChild(t, d, keep, keepRoot, "in_progress")
	require.Equal(t, "in_progress", targetStatus(t, d, keepRoot))
	_, err := d.Exec(`UPDATE targets SET updated_at = '2000-01-01T00:00:00Z' WHERE project_id = ?`, keep)
	require.NoError(t, err)

	require.NoError(t, d.DeleteWorkbench(pid))

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets WHERE project_id = ?`, pid).Scan(&n))
	assert.Zero(t, n)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets
		WHERE project_id = ? AND updated_at = '2000-01-01T00:00:00Z'`, keep).Scan(&n))
	assert.Equal(t, 2, n, "the other project's board is not written")
	assert.Equal(t, "in_progress", targetStatus(t, d, keepChild))
}
