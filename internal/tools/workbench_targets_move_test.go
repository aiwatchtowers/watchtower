package tools

import (
	"database/sql"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// PROJ-09 (board #186): update_target's parent_id moves a target within its
// workbench and refuses a cycle or a parent outside it.
func TestProj09_UpdateTargetMovesUnderAParentAndToTheTopLevel(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	child := db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{}, "Loose task")

	mustApply(t, reg, fx.a, "update_target",
		fmt.Sprintf(`{"target_id":%d,"parent_id":%d,"reason":"group with its feature"}`, child, fx.aTarget))
	got, err := fx.d.GetTargetByID(int(child))
	require.NoError(t, err)
	assert.Equal(t, sql.NullInt64{Int64: fx.aTarget, Valid: true}, got.ParentID)

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"parent_id":0,"reason":"own feature"}`, child))
	got, err = fx.d.GetTargetByID(int(child))
	require.NoError(t, err)
	assert.False(t, got.ParentID.Valid)
}

func TestProj09_UpdateTargetRefusesACycleAndOtherBoards(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	child := db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{Int64: fx.aTarget, Valid: true}, "Task")

	cases := []struct {
		name     string
		args     string
		notHere  bool
		parentOf int64
	}{
		{"itself", fmt.Sprintf(`{"target_id":%d,"parent_id":%d,"reason":"r"}`, fx.aTarget, fx.aTarget), false, fx.aTarget},
		{"its sub-target", fmt.Sprintf(`{"target_id":%d,"parent_id":%d,"reason":"r"}`, fx.aTarget, child), false, fx.aTarget},
		{"another workbench's parent", fmt.Sprintf(`{"target_id":%d,"parent_id":%d,"reason":"r"}`, child, fx.bTarget), true, child},
		{"a personal parent", fmt.Sprintf(`{"target_id":%d,"parent_id":%d,"reason":"r"}`, child, fx.plain), true, child},
		{"negative", fmt.Sprintf(`{"target_id":%d,"parent_id":-1,"reason":"r"}`, child), false, child},
	}
	for _, c := range cases {
		before, err := fx.d.GetTargetByID(int(c.parentOf))
		require.NoError(t, err)
		_, err = proposeIn(t, reg, fx.a, "update_target", c.args)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, c.name)
		if c.notHere {
			require.ErrorIs(t, err, db.ErrNotInWorkbench, c.name)
		}
		after, err := fx.d.GetTargetByID(int(c.parentOf))
		require.NoError(t, err)
		assert.Equal(t, before.ParentID, after.ParentID, "%s: nothing moved", c.name)
	}
}
