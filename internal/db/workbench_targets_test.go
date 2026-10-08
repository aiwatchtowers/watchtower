package db

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateProjectTargetsTx_UsesTheBoardDefaults(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	before := time.Now().UTC().Format("2006-01-02")
	var ids []int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateWorkbenchTargetsTx(tx, pid, ActorAgent, []WorkbenchTargetInput{{Title: "  Ship the board  ", Intent: "why it matters"}})
		return err
	}))
	id := ids[0]
	after := time.Now().UTC().Format("2006-01-02")

	tg, err := d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, nullID(pid), tg.WorkbenchID)
	assert.Equal(t, "Ship the board", tg.Text)
	assert.Equal(t, "why it matters", tg.Intent)
	assert.Equal(t, "custom", tg.Level)
	assert.Equal(t, "project", tg.CustomLabel)
	assert.Contains(t, []string{before, after}, tg.PeriodStart)
	assert.Equal(t, tg.PeriodStart, tg.PeriodEnd)
	assert.Equal(t, "chat", tg.SourceType)
	assert.Equal(t, "mine", tg.Ownership)
	assert.Equal(t, "todo", tg.Status)
}

func TestCreateProjectTargetsTx_NestedBatchParents(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	var ids []int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateWorkbenchTargetsTx(tx, pid, ActorAgent, []WorkbenchTargetInput{
			{Title: "feature"},
			{Title: "task 1", Intent: "docs/plan.md task 1", BatchParent: 1},
			{Title: "step 1.1", BatchParent: 2},
		})
		return err
	}))
	require.Len(t, ids, 3)

	task, err := d.GetTargetByID(int(ids[1]))
	require.NoError(t, err)
	assert.Equal(t, nullID(ids[0]), task.ParentID)
	step, err := d.GetTargetByID(int(ids[2]))
	require.NoError(t, err)
	assert.Equal(t, nullID(ids[1]), step.ParentID)
}

// TestCreateProjectTargetsTx_BatchIsAllOrNothing: one bad item (here the last)
// leaves nothing of the batch behind once the caller's tx rolls back.
func TestCreateProjectTargetsTx_BatchIsAllOrNothing(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	err := d.WithTx(func(tx *sql.Tx) error {
		_, err := d.CreateWorkbenchTargetsTx(tx, pid, ActorAgent, []WorkbenchTargetInput{
			{Title: "feature"},
			{Title: "task 1", BatchParent: 1},
			{Title: "   "},
		})
		return err
	})
	assert.ErrorContains(t, err, "target 3 of 3")

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets WHERE project_id = ?`, pid).Scan(&n))
	assert.Zero(t, n)
}

func TestCreateProjectTargetsTx_RefusesParentsOutsideTheProject(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	foreign := SeedTestWorkbenchTarget(t, d, newTestWorkbench(t, d), sql.NullInt64{}, "other board")
	personal, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	create := func(items ...WorkbenchTargetInput) error {
		return d.WithTx(func(tx *sql.Tx) error {
			_, err := d.CreateWorkbenchTargetsTx(tx, pid, ActorAgent, items)
			return err
		})
	}
	assert.ErrorIs(t, create(WorkbenchTargetInput{Title: "x", ParentID: nullID(foreign)}), ErrNotInWorkbench)
	assert.ErrorIs(t, create(WorkbenchTargetInput{Title: "x", ParentID: nullID(personal)}), ErrNotInWorkbench)
	assert.ErrorContains(t, create(WorkbenchTargetInput{Title: "x", BatchParent: 1}), "not an earlier item")
	assert.ErrorContains(t, create(WorkbenchTargetInput{Title: "a"}, WorkbenchTargetInput{Title: "b", BatchParent: 1, ParentID: nullID(foreign)}),
		"mutually exclusive")

	err = d.WithTx(func(tx *sql.Tx) error {
		_, err := d.CreateWorkbenchTargetsTx(tx, pid+100, ActorAgent, []WorkbenchTargetInput{{Title: "x"}})
		return err
	})
	assert.ErrorIs(t, err, ErrWorkbenchNotFound)
}

func TestTargets_ProjectIDRoundTripsThroughCreateAndUpdate(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id, err := d.CreateTarget(Target{Text: "board item", Status: "todo", Priority: "medium", Ownership: "mine",
		SourceType: "chat", WorkbenchID: nullID(pid)})
	require.NoError(t, err)

	tg, err := d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, nullID(pid), tg.WorkbenchID)

	tg.Text = "renamed"
	require.NoError(t, d.UpdateTarget(*tg))
	tg, err = d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, nullID(pid), tg.WorkbenchID, "a full-row update keeps the board")
}

func TestGetTargets_ProjectScope(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	_, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	mine := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "on my board")
	SeedTestWorkbenchTarget(t, d, other, sql.NullInt64{}, "on another board")

	personal, err := d.GetTargets(TargetFilter{})
	require.NoError(t, err)
	require.Len(t, personal, 1)
	assert.Equal(t, "personal", personal[0].Text)

	board, err := d.GetTargets(TargetFilter{WorkbenchID: pid, IncludeDone: true})
	require.NoError(t, err)
	require.Len(t, board, 1)
	assert.Equal(t, int(mine), board[0].ID)
}

func TestPromoteSubItemToChild_CopiesProjectID(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	parent := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "feature")
	_, err := d.Exec(`UPDATE targets SET sub_items = '[{"text":"write the test","done":false}]' WHERE id = ?`, parent)
	require.NoError(t, err)

	child, err := d.PromoteSubItemToChild(parent, 0, PromoteOverrides{})
	require.NoError(t, err)
	tg, err := d.GetTargetByID(int(child))
	require.NoError(t, err)
	assert.Equal(t, nullID(pid), tg.WorkbenchID, "a promoted sub-item stays on the parent's board")
}

// PROJ-06: the creation row carries the actor the caller claims — the agent's
// create_targets or the owner's `workbench target add` — and nothing else.
func TestCreateWorkbenchTargetsTx_RecordsTheClaimedActor(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	for _, actor := range []string{ActorAgent, ActorOwner} {
		var ids []int64
		require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
			var err error
			ids, err = d.CreateWorkbenchTargetsTx(tx, pid, actor, []WorkbenchTargetInput{{Title: "by " + actor}})
			return err
		}))
		var got string
		var claim sql.NullString
		require.NoError(t, d.QueryRow(`SELECT actor FROM target_status_history WHERE target_id = ?`, ids[0]).Scan(&got))
		require.NoError(t, d.QueryRow(`SELECT status_actor FROM targets WHERE id = ?`, ids[0]).Scan(&claim))
		assert.Equal(t, actor, got)
		assert.False(t, claim.Valid, "the history trigger cleared the claim")
	}
	for _, actor := range []string{"", ActorSystem, "bogus"} {
		err := d.WithTx(func(tx *sql.Tx) error {
			_, err := d.CreateWorkbenchTargetsTx(tx, pid, actor, []WorkbenchTargetInput{{Title: "x"}})
			return err
		})
		assert.Error(t, err, "actor %q is refused", actor)
	}
}
