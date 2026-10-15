package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLinearAccount_Lifecycle(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateLinearAccount("Work")
	require.NoError(t, err)
	require.NoError(t, d.UpdateLinearAccountConnection(id, "org-1", "acme", "Acme"))
	require.NoError(t, d.SetLinearAccountOwner(id, "user-1", "owner@example.com", "Owner"))

	a, err := d.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", a.URLKey)
	assert.Equal(t, "user-1", a.OwnerUserID)
	assert.True(t, a.Enabled)
	assert.Equal(t, "ok", a.Status)

	require.NoError(t, d.SetLinearAccountAuthState(id, "revoked", "invalid_grant"))
	require.NoError(t, d.SetLinearAccountRemoved(id))
	enabled, err := d.ListEnabledLinearAccounts()
	require.NoError(t, err)
	assert.Empty(t, enabled)
	all, err := d.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, all, 1) // soft delete: the row stays

	_, err = d.GetLinearAccount(99)
	assert.ErrorIs(t, err, ErrLinearAccountNotFound)
}

func TestLinearTeams_UpsertKeepsSelection(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.UpsertLinearTeams(id, []LinearTeam{{ID: "t-1", Key: "ENG", Name: "Eng"}, {ID: "t-2", Key: "OPS", Name: "Ops"}},
		map[string]bool{"t-1": true}))
	require.NoError(t, d.SetLinearTeamSelected(id, "OPS", true))
	require.NoError(t, d.SetLinearTeamSelected(id, "ENG", false))
	// A later pass renames ENG and proposes selecting it again: selection is the user's, not the sync's.
	require.NoError(t, d.UpsertLinearTeams(id, []LinearTeam{{ID: "t-1", Key: "ENG", Name: "Engineering"}}, map[string]bool{"t-1": true}))
	teams, err := d.ListLinearTeams(id)
	require.NoError(t, err)
	require.Len(t, teams, 2)
	assert.Equal(t, "Engineering", teams[0].Name)
	assert.False(t, teams[0].IsSelected)
	assert.True(t, teams[1].IsSelected)
	assert.Error(t, d.SetLinearTeamSelected(id, "NOPE", true))
}

func TestLinearSyncState_ErrorKeepsWatermark(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.RecordLinearSyncSuccess(id, "t-1", "2026-10-01T00:00:00.000Z", "2026-10-01T00:05:00Z"))
	require.NoError(t, d.RecordLinearSyncError(id, "t-1", "RATELIMITED"))
	s, err := d.GetLinearSyncState(id, "t-1")
	require.NoError(t, err)
	assert.Equal(t, "2026-10-01T00:00:00.000Z", s.Watermark)
	assert.Equal(t, "RATELIMITED", s.LastError)
	// A clean pass with no new issues keeps the watermark and clears the error.
	require.NoError(t, d.RecordLinearSyncSuccess(id, "t-1", "", "2026-10-01T00:10:00Z"))
	s, _ = d.GetLinearSyncState(id, "t-1")
	assert.Equal(t, "2026-10-01T00:00:00.000Z", s.Watermark)
	assert.Empty(t, s.LastError)
}

func TestLinearAccount_AutoLabel(t *testing.T) {
	d := openTestDB(t)
	a, _ := d.CreateLinearAccount("")
	b, _ := d.CreateLinearAccount("")
	require.NoError(t, d.UpdateLinearAccountConnection(a, "org-1", "acme", "Acme"))
	require.NoError(t, d.UpdateLinearAccountConnection(b, "org-2", "acme2", "Acme"))
	ga, _ := d.GetLinearAccount(a)
	gb, _ := d.GetLinearAccount(b)
	assert.Equal(t, "Acme", ga.Label)
	assert.Equal(t, "Acme 2", gb.Label)
	assert.Error(t, d.SetLinearAccountEnabled(99, false))
}
