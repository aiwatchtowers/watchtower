package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLinearTeamStates_ReplaceAndOrder(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.ReplaceLinearTeamStates(id, "t-1", []LinearWorkflowState{
		{TeamID: "t-1", ID: "s-2", Name: "Done", Type: "completed", Position: 3},
		{TeamID: "t-1", ID: "s-1", Name: "Todo", Type: "unstarted", Position: 1},
		{TeamID: "t-1", ID: "s-3", Name: "Backlog", Type: "backlog", Position: 1},
	}))
	require.NoError(t, d.ReplaceLinearTeamStates(id, "t-2", []LinearWorkflowState{{TeamID: "t-2", ID: "s-9", Name: "X", Type: "started"}}))
	got, err := d.ListLinearTeamStates(id, "t-1")
	require.NoError(t, err)
	require.Len(t, got, 3)
	assert.Equal(t, []string{"Backlog", "Todo", "Done"}, []string{got[0].Name, got[1].Name, got[2].Name})
	assert.Equal(t, id, got[0].AccountID)

	require.NoError(t, d.ReplaceLinearTeamStates(id, "t-1", []LinearWorkflowState{{TeamID: "t-1", ID: "s-1", Name: "Todo", Type: "unstarted"}}))
	got, _ = d.ListLinearTeamStates(id, "t-1")
	require.Len(t, got, 1)
	other, _ := d.ListLinearTeamStates(id, "t-2")
	assert.Len(t, other, 1, "replacing one team leaves the others")
}

func TestLinearLabels_TeamPlusWorkspace(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.ReplaceLinearLabels(id, "t-1", []LinearLabel{{ID: "l-1", Name: "Bug"}}))
	require.NoError(t, d.ReplaceLinearLabels(id, "t-2", []LinearLabel{{ID: "l-2", Name: "Ops"}}))
	require.NoError(t, d.ReplaceLinearLabels(id, "", []LinearLabel{{ID: "l-3", Name: "Company"}}))
	got, err := d.ListLinearLabels(id, "t-1")
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "Bug", got[0].Name)
	assert.Equal(t, "Company", got[1].Name)
	assert.Equal(t, "", got[1].TeamID)

	// Replacing the workspace labels leaves team labels alone.
	require.NoError(t, d.ReplaceLinearLabels(id, "", nil))
	got, _ = d.ListLinearLabels(id, "t-1")
	require.Len(t, got, 1)
}
