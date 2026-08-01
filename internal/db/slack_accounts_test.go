package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSlackAccountCreateListGetRoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateSlackAccount(SlackAccount{
		TeamID: "T1", TeamName: "Acme", TeamDomain: "acme", Label: "Work",
		CurrentUserID: "1:U0123",
	})
	require.NoError(t, err)
	assert.Equal(t, int64(1), id)

	id2, err := d.CreateSlackAccount(SlackAccount{TeamID: "T2", TeamName: "Beta", Label: "Personal"})
	require.NoError(t, err)
	assert.Equal(t, int64(2), id2)

	accounts, err := d.ListSlackAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 2)
	// ORDER BY id ASC
	assert.Equal(t, id, accounts[0].ID)
	assert.Equal(t, "T1", accounts[0].TeamID)
	assert.Equal(t, "Acme", accounts[0].TeamName)
	assert.Equal(t, "acme", accounts[0].TeamDomain)
	assert.Equal(t, "Work", accounts[0].Label)
	assert.Equal(t, "1:U0123", accounts[0].CurrentUserID)
	assert.Equal(t, "ok", accounts[0].Status)
	assert.True(t, accounts[0].Enabled)
	assert.NotEmpty(t, accounts[0].CreatedAt)
	assert.Equal(t, id2, accounts[1].ID)
	assert.Equal(t, "T2", accounts[1].TeamID)

	got, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "T1", got.TeamID)
	assert.Equal(t, "Work", got.Label)

	_, err = d.GetSlackAccount(999)
	assert.Error(t, err)
}

func TestSlackAccount_UpdateConnection(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateSlackAccount(SlackAccount{Label: "New"})
	require.NoError(t, err)

	require.NoError(t, d.UpdateSlackAccountConnection(id, "T9", "Resolved", "resolved", "1:U9"))

	got, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "T9", got.TeamID)
	assert.Equal(t, "Resolved", got.TeamName)
	assert.Equal(t, "resolved", got.TeamDomain)
	assert.Equal(t, "1:U9", got.CurrentUserID)
}

func TestSlackAccount_SetLabel(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateSlackAccount(SlackAccount{Label: "Old"})
	require.NoError(t, err)

	require.NoError(t, d.SetSlackAccountLabel(id, "New Label"))

	got, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "New Label", got.Label)
}

func TestSlackAccount_SetEnabled(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateSlackAccount(SlackAccount{Label: "A"})
	require.NoError(t, err)

	require.NoError(t, d.SetSlackAccountEnabled(id, false))

	got, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.False(t, got.Enabled)
}

// TestSlackAccount_SetAuthState_MissingRow mirrors SetEmailAccountAuthState's
// RowsAffected()==0 error shape (email_accounts.go:195) for a missing row.
func TestSlackAccount_SetAuthState_MissingRow(t *testing.T) {
	d := openTestDB(t)

	err := d.SetSlackAccountAuthState(999, "error", "boom")
	require.Error(t, err)
}

func TestSlackAccount_SetAuthState_RoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateSlackAccount(SlackAccount{Label: "A"})
	require.NoError(t, err)

	require.NoError(t, d.SetSlackAccountAuthState(id, "revoked", "token expired"))

	got, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "revoked", got.Status)
	assert.Equal(t, "token expired", got.Error)
}

// TestSlackAccount_SetRemoved_NonDestructive verifies removal marks the row
// removed/disabled without deleting it — GetSlackAccount/ListSlackAccounts
// still return it, but ListEnabledSlackAccounts excludes it.
func TestSlackAccount_SetRemoved_NonDestructive(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateSlackAccount(SlackAccount{Label: "A", CurrentUserID: "1:U1"})
	require.NoError(t, err)

	require.NoError(t, d.SetSlackAccountRemoved(id))

	got, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "removed", got.Status)
	assert.False(t, got.Enabled)

	accounts, err := d.ListSlackAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)

	enabled, err := d.ListEnabledSlackAccounts()
	require.NoError(t, err)
	assert.Empty(t, enabled)
}

func TestSlackAccount_SearchWatermark_FreshAccountReturnsEmpty(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateSlackAccount(SlackAccount{Label: "A"})
	require.NoError(t, err)

	date, err := d.GetSlackAccountSearchWatermark(id)
	require.NoError(t, err)
	assert.Equal(t, "", date)
}

func TestSlackAccount_SearchWatermark_RoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateSlackAccount(SlackAccount{Label: "A"})
	require.NoError(t, err)

	require.NoError(t, d.SetSlackAccountSearchWatermark(id, "2026-07-30"))

	date, err := d.GetSlackAccountSearchWatermark(id)
	require.NoError(t, err)
	assert.Equal(t, "2026-07-30", date)
}

func TestSlackAccount_ListOwnerSlackUserIDs(t *testing.T) {
	d := openTestDB(t)

	enabledID, err := d.CreateSlackAccount(SlackAccount{Label: "Enabled", CurrentUserID: "1:U1"})
	require.NoError(t, err)

	disabledID, err := d.CreateSlackAccount(SlackAccount{Label: "Disabled", CurrentUserID: "2:U2"})
	require.NoError(t, err)
	require.NoError(t, d.SetSlackAccountEnabled(disabledID, false))

	ids, err := d.ListOwnerSlackUserIDs()
	require.NoError(t, err)
	assert.Equal(t, []string{"1:U1"}, ids)
	_ = enabledID
}

// TestSlackAccount_ListOwnerSlackUserIDs_EmptyCurrentUserExcluded covers the
// mid-OAuth degenerate case: an enabled account whose current_user_id hasn't
// resolved yet is silently excluded, not an error.
func TestSlackAccount_ListOwnerSlackUserIDs_EmptyCurrentUserExcluded(t *testing.T) {
	d := openTestDB(t)

	_, err := d.CreateSlackAccount(SlackAccount{Label: "Mid-OAuth"})
	require.NoError(t, err)

	ids, err := d.ListOwnerSlackUserIDs()
	require.NoError(t, err)
	assert.Empty(t, ids)
}

func TestSlackAccount_ListOwnerSlackUserIDs_NoAccounts(t *testing.T) {
	d := openTestDB(t)

	ids, err := d.ListOwnerSlackUserIDs()
	require.NoError(t, err)
	assert.Empty(t, ids)
}

func TestGetCurrentUserID_NoSlackAccountsReturnsEmpty(t *testing.T) {
	d := openTestDB(t)

	userID, err := d.GetCurrentUserID()
	require.NoError(t, err)
	assert.Equal(t, "", userID)
}

func TestGetCurrentUserID_PinnedToAccountOne(t *testing.T) {
	d := openTestDB(t)

	id1, err := d.CreateSlackAccount(SlackAccount{Label: "First", CurrentUserID: "1:U1"})
	require.NoError(t, err)
	require.Equal(t, int64(1), id1)

	userID, err := d.GetCurrentUserID()
	require.NoError(t, err)
	assert.Equal(t, "1:U1", userID)

	_, err = d.CreateSlackAccount(SlackAccount{Label: "Second", CurrentUserID: "2:U2"})
	require.NoError(t, err)

	// Still pinned to account #1's value, unaffected by account #2.
	userID, err = d.GetCurrentUserID()
	require.NoError(t, err)
	assert.Equal(t, "1:U1", userID)
}

func TestFormatConnectedWorkspaces(t *testing.T) {
	// Empty slice -> "".
	assert.Equal(t, "", FormatConnectedWorkspaces(nil))
	assert.Equal(t, "", FormatConnectedWorkspaces([]SlackAccount{}))

	// One account: label present + domain.
	one := []SlackAccount{
		{TeamName: "Acme Inc", TeamDomain: "acme", Label: "Work"},
	}
	assert.Equal(t, "Work (acme)", FormatConnectedWorkspaces(one))

	// Two accounts: label falls back to team name when empty; a missing
	// domain drops the parenthetical entirely.
	two := []SlackAccount{
		{TeamName: "Acme Inc", TeamDomain: "acme", Label: "Work"},
		{TeamName: "Beta LLC", TeamDomain: "", Label: ""},
	}
	assert.Equal(t, "Work (acme), Beta LLC", FormatConnectedWorkspaces(two))
}
