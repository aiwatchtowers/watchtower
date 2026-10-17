package tools

import (
	"context"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfiles"
)

// Spec 2026-10-02 §5.2: the five renamed tools map back from their old
// names, and every one of them belongs to WorkbenchTools — DEV-06 (fifteen,
// plus get_review since 2026-10-16: sixteen, plus annotate_changes and
// reply_review_comment: eighteen). The old names are only
// resolved, never registered or served.
func TestCanonicalToolName_MapsTheRenamedWorkbenchTools(t *testing.T) {
	var names []string
	for _, tool := range WorkbenchTools(workbenchfiles.Store{}) {
		names = append(names, tool.Name)
	}
	require.Len(t, names, 18)
	require.Len(t, preRenameWorkbenchToolNames, 5)
	for oldName, newName := range preRenameWorkbenchToolNames {
		assert.Contains(t, names, newName)
		assert.NotContains(t, names, oldName, "an old name is never registered as a tool of its own")
		assert.Equal(t, newName, CanonicalToolName(oldName))
		assert.Equal(t, newName, CanonicalToolName(newName))
	}
	assert.Equal(t, "create_targets", CanonicalToolName("create_targets"))
}

func TestRegistryGet_ResolvesBothSpellings(t *testing.T) {
	reg := workbenchRegistry(t, openDB(t))
	for oldName, newName := range preRenameWorkbenchToolNames {
		byOld, ok := reg.Get(oldName)
		require.True(t, ok, oldName)
		byNew, ok := reg.Get(newName)
		require.True(t, ok, newName)
		assert.Same(t, byNew, byOld)
		assert.Equal(t, newName, byOld.Name)
	}
	_, ok := reg.Get("project_targets")
	assert.False(t, ok, "only the five renamed tools have an alias")
}

// A row recorded before the rename carries the old tool name; Apply (a
// retried `actions apply`) still finds its tool.
func TestLegacyName_RowStoredUnderAnOldNameStillApplies(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	id, err := fx.d.InsertAgentAction(db.AgentAction{
		Tool: "update_project", ArgsJSON: `{"description":"From before the rename.","reason":"r"}`, Reason: "r",
		Surface: WorkbenchSurface, ContextType: WorkbenchContextType, ContextID: strconv.FormatInt(fx.a, 10),
		Status: "approved", TrustAtCreate: "execute",
	})
	require.NoError(t, err)

	row, err := reg.Apply(context.Background(), id)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status, row.Error)
	p, err := fx.d.GetWorkbench(fx.a)
	require.NoError(t, err)
	assert.Equal(t, "From before the rename.", p.Description)
}
