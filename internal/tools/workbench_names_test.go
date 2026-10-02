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

// Spec 2026-10-02 §5.2: the five renamed tools keep their old names as
// aliases, and every one of them belongs to WorkbenchTools — DEV-06's eleven.
func TestLegacyWorkbenchToolNames_CoverTheRenamedWorkbenchTools(t *testing.T) {
	var names []string
	for _, tool := range WorkbenchTools(workbenchfiles.Store{}, false) {
		names = append(names, tool.Name)
	}
	require.Len(t, names, 11)
	require.Len(t, LegacyWorkbenchToolNames, 5)
	for newName, oldName := range LegacyWorkbenchToolNames {
		assert.Contains(t, names, newName)
		assert.NotContains(t, names, oldName, "an old name is never registered as a tool of its own")
		assert.Equal(t, newName, CanonicalToolName(oldName))
		assert.Equal(t, newName, CanonicalToolName(newName))
	}
	assert.Equal(t, "create_targets", CanonicalToolName("create_targets"))
}

func TestRegistryGet_ResolvesBothSpellings(t *testing.T) {
	reg := workbenchRegistry(t, openDB(t))
	for newName, oldName := range LegacyWorkbenchToolNames {
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

// A write through a legacy name records the canonical name in
// agent_actions.tool; a read through one answers like the new name.
func TestLegacyName_WriteRecordsTheCanonicalName(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)

	rc, err := proposeIn(t, reg, fx.a, "update_project", `{"description":"Legacy setup.","reason":"setup"}`)
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, "%+v", rc)
	assert.Equal(t, UpdateWorkbenchTool, rc.Tool)

	row, err := fx.d.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, UpdateWorkbenchTool, row.Tool, "agent_actions.tool is always the new name")

	assert.Equal(t, callReadIn(t, reg, fx.a, WorkbenchInfoTool, `{}`), callReadIn(t, reg, fx.a, "project_info", `{}`))
	assert.Contains(t, callReadIn(t, reg, fx.a, "project_info", `{}`), `"description":"Legacy setup."`)
}

// A row recorded before the rename carries the old tool name; Apply (a
// retried `actions apply`) still finds its tool.
func TestLegacyName_RowStoredUnderAnOldNameStillApplies(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	id, err := fx.d.InsertAgentAction(db.AgentAction{
		Tool: "update_project", ArgsJSON: `{"description":"From before the rename.","reason":"r"}`, Reason: "r",
		Surface: workbenchSurface, ContextType: WorkbenchContextType, ContextID: strconv.FormatInt(fx.a, 10),
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

func TestBindingSpell_LegacySessionsReadTheOldNames(t *testing.T) {
	text := "Remove a source (id from workbench_info); add one with add_workbench_source, then workbench_board."
	assert.Equal(t, text, Binding{}.Spell(text))
	assert.Equal(t, "Remove a source (id from project_info); add one with add_project_source, then project_board.",
		Binding{LegacyNames: true}.Spell(text))
	for newName, oldName := range LegacyWorkbenchToolNames {
		assert.Equal(t, oldName, Binding{LegacyNames: true}.Spell(newName))
	}
	// Every description of a workbench tool names only tools a legacy
	// session lists once spelled.
	legacy := Binding{LegacyNames: true}
	for _, tool := range WorkbenchTools(workbenchfiles.Store{}, false) {
		for newName := range LegacyWorkbenchToolNames {
			assert.NotContains(t, legacy.Spell(tool.Description), newName, tool.Name)
		}
	}
}
