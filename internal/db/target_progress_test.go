package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// SetTargetProgress stores an explicit leaf progress and rolls it up into
// the parent, the way a status change does.
func TestSetTargetProgress_StoresValueAndRecomputesParent(t *testing.T) {
	d := openTestDB(t)
	parent, err := d.CreateTarget(Target{Text: "parent", Level: "week", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	child, err := d.CreateTarget(Target{Text: "child", Level: "week", Status: "in_progress", Priority: "medium",
		Ownership: "mine", SourceType: "manual", ParentID: sql.NullInt64{Int64: parent, Valid: true}})
	require.NoError(t, err)

	require.NoError(t, d.SetTargetProgress(int(child), 0.5))

	got, err := d.GetTargetByID(int(child))
	require.NoError(t, err)
	assert.InDelta(t, 0.5, got.Progress, 1e-9)
	up, err := d.GetTargetByID(int(parent))
	require.NoError(t, err)
	assert.InDelta(t, 0.5, up.Progress, 1e-9)

	assert.Error(t, d.SetTargetProgress(99999, 0.1), "a missing target is an error")
}
