package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestJiraAccountCreateListGetRoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateJiraAccount(JiraAccount{
		CloudID: "cloud-1", SiteURL: "https://acme.atlassian.net", SiteName: "Acme", Label: "Work",
	})
	require.NoError(t, err)
	assert.Equal(t, int64(1), id)

	id2, err := d.CreateJiraAccount(JiraAccount{CloudID: "cloud-2", SiteName: "Beta", Label: "Personal"})
	require.NoError(t, err)
	assert.Equal(t, int64(2), id2)

	accounts, err := d.ListJiraAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 2)
	// ORDER BY id ASC
	assert.Equal(t, id, accounts[0].ID)
	assert.Equal(t, "cloud-1", accounts[0].CloudID)
	assert.Equal(t, "https://acme.atlassian.net", accounts[0].SiteURL)
	assert.Equal(t, "Acme", accounts[0].SiteName)
	assert.Equal(t, "Work", accounts[0].Label)
	assert.Equal(t, "ok", accounts[0].Status)
	assert.True(t, accounts[0].Enabled)
	assert.Equal(t, float64(0), accounts[0].MemoryJiraLastExtractedTS)
	assert.NotEmpty(t, accounts[0].CreatedAt)
	assert.Equal(t, id2, accounts[1].ID)
	assert.Equal(t, "cloud-2", accounts[1].CloudID)

	got, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "cloud-1", got.CloudID)
	assert.Equal(t, "Work", got.Label)

	_, err = d.GetJiraAccount(999)
	assert.Error(t, err)
}

func TestJiraAccount_UpdateConnection(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateJiraAccount(JiraAccount{Label: "New"})
	require.NoError(t, err)

	require.NoError(t, d.UpdateJiraAccountConnection(id, "cloud-9", "https://resolved.atlassian.net", "Resolved"))

	got, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "cloud-9", got.CloudID)
	assert.Equal(t, "https://resolved.atlassian.net", got.SiteURL)
	assert.Equal(t, "Resolved", got.SiteName)

	// Missing row errors (RowsAffected()==0 shape).
	require.Error(t, d.UpdateJiraAccountConnection(999, "c", "u", "n"))
}

func TestJiraAccount_SetEnabled(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateJiraAccount(JiraAccount{Label: "A"})
	require.NoError(t, err)

	require.NoError(t, d.SetJiraAccountEnabled(id, false))

	got, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	assert.False(t, got.Enabled)

	require.Error(t, d.SetJiraAccountEnabled(999, true))
}

// TestJiraAccount_SetAuthState_MissingRow mirrors SetSlackAccountAuthState's
// RowsAffected()==0 error shape for a missing row.
func TestJiraAccount_SetAuthState_MissingRow(t *testing.T) {
	d := openTestDB(t)

	err := d.SetJiraAccountAuthState(999, "error", "boom")
	require.Error(t, err)
}

func TestJiraAccount_SetAuthState_RoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateJiraAccount(JiraAccount{Label: "A"})
	require.NoError(t, err)

	require.NoError(t, d.SetJiraAccountAuthState(id, "revoked", "token expired"))

	got, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "revoked", got.Status)
	assert.Equal(t, "token expired", got.Error)
}

// TestJiraAccount_SetRemoved_NonDestructive verifies removal marks the row
// removed/disabled without deleting it — GetJiraAccount/ListJiraAccounts
// still return it, but ListEnabledJiraAccounts excludes it.
func TestJiraAccount_SetRemoved_NonDestructive(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateJiraAccount(JiraAccount{Label: "A"})
	require.NoError(t, err)

	require.NoError(t, d.SetJiraAccountRemoved(id))

	got, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "removed", got.Status)
	assert.False(t, got.Enabled)

	accounts, err := d.ListJiraAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)

	enabled, err := d.ListEnabledJiraAccounts()
	require.NoError(t, err)
	assert.Empty(t, enabled)

	require.Error(t, d.SetJiraAccountRemoved(999))
}

// TestJiraAccount_MemoryWatermark_FreshAccountReadsZero: the per-account
// extraction watermark starts at 0 on a fresh row and round-trips (full
// missing-row semantics are covered by TestMemoryJiraWatermark).
func TestJiraAccount_MemoryWatermark_FreshAccountReadsZero(t *testing.T) {
	d := openTestDB(t)

	id := SeedTestJiraAccount(t, d)

	wm, err := d.MemoryJiraWatermark(id)
	require.NoError(t, err)
	assert.Equal(t, float64(0), wm)

	require.NoError(t, d.SetMemoryJiraWatermark(id, 1784500000))

	got, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, float64(1784500000), got.MemoryJiraLastExtractedTS)
}
