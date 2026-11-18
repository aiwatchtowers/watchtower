package db

import (
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSlackAppSetups_InsertGetList(t *testing.T) {
	d := openTestDB(t)

	require.NoError(t, d.InsertSlackAppSetup(SlackAppSetup{
		TeamID: "T0ACME", TeamName: "Acme", AppID: "A0APP1", ClientID: "111.222",
	}))
	require.NoError(t, d.InsertSlackAppSetup(SlackAppSetup{
		TeamID: "T0BETA", AppID: "A0APP2", ClientID: "333.444",
	}))

	got, err := d.GetSlackAppSetup("T0ACME")
	require.NoError(t, err)
	assert.Equal(t, "T0ACME", got.TeamID)
	assert.Equal(t, "Acme", got.TeamName)
	assert.Equal(t, "A0APP1", got.AppID)
	assert.Equal(t, "111.222", got.ClientID)
	assert.False(t, got.LinkWritten)
	assert.Empty(t, got.InstallRequestedAt)
	assert.NotEmpty(t, got.CreatedAt)
	assert.Equal(t, got.CreatedAt, got.UpdatedAt)

	_, err = d.GetSlackAppSetup("T0NONE")
	assert.True(t, errors.Is(err, sql.ErrNoRows), "a missing team reads as sql.ErrNoRows, got %v", err)

	all, err := d.ListSlackAppSetups()
	require.NoError(t, err)
	require.Len(t, all, 2)
	assert.Equal(t, "T0ACME", all[0].TeamID)
	assert.Equal(t, "T0BETA", all[1].TeamID)
}

// Rows inserted within the same second list in insertion order, not by team id.
func TestSlackAppSetups_ListInsertionOrder(t *testing.T) {
	d := openTestDB(t)
	for _, team := range []string{"T0ZULU", "T0ALPHA", "T0MIKE"} {
		require.NoError(t, d.InsertSlackAppSetup(SlackAppSetup{TeamID: team, AppID: "A0APP", ClientID: "1.2"}))
	}
	_, err := d.Exec(`UPDATE slack_app_setups SET created_at = '2026-11-17T10:00:00Z'`)
	require.NoError(t, err)

	all, err := d.ListSlackAppSetups()
	require.NoError(t, err)
	require.Len(t, all, 3)
	assert.Equal(t, []string{"T0ZULU", "T0ALPHA", "T0MIKE"}, []string{all[0].TeamID, all[1].TeamID, all[2].TeamID})
}

func TestSlackAppSetups_SecondInsertRefused(t *testing.T) {
	d := openTestDB(t)

	require.NoError(t, d.InsertSlackAppSetup(SlackAppSetup{TeamID: "T0ACME", AppID: "A0APP1", ClientID: "111.222"}))
	err := d.InsertSlackAppSetup(SlackAppSetup{TeamID: "T0ACME", AppID: "A0APP9", ClientID: "999.999"})
	require.ErrorIs(t, err, ErrSetupExists)

	got, err := d.GetSlackAppSetup("T0ACME")
	require.NoError(t, err)
	assert.Equal(t, "A0APP1", got.AppID, "the first setup is kept")
	assert.Equal(t, "111.222", got.ClientID)
}

func TestSlackAppSetups_LinkWrittenAndInstallRequested(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.InsertSlackAppSetup(SlackAppSetup{TeamID: "T0ACME", AppID: "A0APP1", ClientID: "111.222"}))

	require.NoError(t, d.SetSlackAppSetupLinkWritten("T0ACME"))
	at := time.Date(2026, 11, 17, 9, 30, 0, 0, time.FixedZone("x", 3600))
	require.NoError(t, d.SetSlackAppSetupInstallRequested("T0ACME", at))

	got, err := d.GetSlackAppSetup("T0ACME")
	require.NoError(t, err)
	assert.True(t, got.LinkWritten)
	assert.Equal(t, "2026-11-17T08:30:00Z", got.InstallRequestedAt)
	assert.NotEmpty(t, got.UpdatedAt)

	// Zero clears.
	require.NoError(t, d.SetSlackAppSetupInstallRequested("T0ACME", time.Time{}))
	got, err = d.GetSlackAppSetup("T0ACME")
	require.NoError(t, err)
	assert.Empty(t, got.InstallRequestedAt)
	assert.True(t, got.LinkWritten)

	// A missing team is an error, not a silent no-op.
	assert.Error(t, d.SetSlackAppSetupLinkWritten("T0NONE"))
	assert.Error(t, d.SetSlackAppSetupInstallRequested("T0NONE", at))
}

func TestSlackAccounts_ClientIDRoundTrip(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSlackAccount(SlackAccount{TeamID: "T0ACME"})
	require.NoError(t, err)

	a, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Empty(t, a.ClientID)
	assert.Empty(t, a.AppID)
	assert.Empty(t, a.RefreshTokenExpiresAt)

	require.NoError(t, d.SetSlackAccountApp(id, "111.222", "A0APP1"))
	exp := time.Date(2027, 1, 2, 3, 4, 5, 0, time.UTC)
	require.NoError(t, d.SetSlackRefreshExpiry(id, exp))

	a, err = d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "111.222", a.ClientID)
	assert.Equal(t, "A0APP1", a.AppID)
	assert.Equal(t, "2027-01-02T03:04:05Z", a.RefreshTokenExpiresAt)

	listed, err := d.ListSlackAccounts()
	require.NoError(t, err)
	require.Len(t, listed, 1)
	assert.Equal(t, "111.222", listed[0].ClientID)
	assert.Equal(t, "A0APP1", listed[0].AppID)
	enabled, err := d.ListEnabledSlackAccounts()
	require.NoError(t, err)
	require.Len(t, enabled, 1)
	assert.Equal(t, "2027-01-02T03:04:05Z", enabled[0].RefreshTokenExpiresAt)

	// Zero clears the refresh expiry (no rotation).
	require.NoError(t, d.SetSlackRefreshExpiry(id, time.Time{}))
	a, err = d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Empty(t, a.RefreshTokenExpiresAt)

	assert.Error(t, d.SetSlackAccountApp(999, "1.2", "A0X"))
	assert.Error(t, d.SetSlackRefreshExpiry(999, exp))
}

func TestSlackAccounts_SetClientIDKeepsOrDropsAppID(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSlackAccount(SlackAccount{TeamID: "T0ACME"})
	require.NoError(t, err)
	require.NoError(t, d.SetSlackAccountApp(id, "111.222", "A0APP1"))

	require.NoError(t, d.SetSlackAccountClientID(id, "111.222"))
	a, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "A0APP1", a.AppID, "same app keeps its App ID")

	require.NoError(t, d.SetSlackAccountClientID(id, "333.444"))
	a, err = d.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "333.444", a.ClientID)
	assert.Empty(t, a.AppID, "another app drops the App ID")

	assert.Error(t, d.SetSlackAccountClientID(999, "1.2"))
}

func TestBackfillSlackClientIDs_OnlyEmptyRows(t *testing.T) {
	d := openTestDB(t)
	empty1, err := d.CreateSlackAccount(SlackAccount{TeamID: "T0ACME"})
	require.NoError(t, err)
	set, err := d.CreateSlackAccount(SlackAccount{TeamID: "T0BETA"})
	require.NoError(t, err)
	require.NoError(t, d.SetSlackAccountApp(set, "555.666", "A0APP5"))
	empty2, err := d.CreateSlackAccount(SlackAccount{TeamID: "T0GAMMA"})
	require.NoError(t, err)

	n, err := d.BackfillSlackClientIDs("111.222")
	require.NoError(t, err)
	assert.Equal(t, int64(2), n)

	for _, id := range []int64{empty1, empty2} {
		a, err := d.GetSlackAccount(id)
		require.NoError(t, err)
		assert.Equal(t, "111.222", a.ClientID)
	}
	a, err := d.GetSlackAccount(set)
	require.NoError(t, err)
	assert.Equal(t, "555.666", a.ClientID, "a set id is never overwritten")

	// Idempotent: nothing left to fill, even with another id.
	n, err = d.BackfillSlackClientIDs("999.999")
	require.NoError(t, err)
	assert.Equal(t, int64(0), n)
	a, err = d.GetSlackAccount(empty1)
	require.NoError(t, err)
	assert.Equal(t, "111.222", a.ClientID)
}

func TestSlackAppSetups_PendingFillAndDelete(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.InsertSlackAppSetup(SlackAppSetup{TeamID: "T0ACME", TeamName: "Acme"}))
	require.NoError(t, d.SetSlackAppSetupApp("T0ACME", "A0APP1", "111.222"))
	got, err := d.GetSlackAppSetup("T0ACME")
	require.NoError(t, err)
	assert.Equal(t, "A0APP1", got.AppID)
	assert.Equal(t, "111.222", got.ClientID)
	require.Error(t, d.SetSlackAppSetupApp("T0NONE", "A0X", "1.2"))

	require.NoError(t, d.DeleteSlackAppSetup("T0ACME"))
	require.NoError(t, d.DeleteSlackAppSetup("T0ACME"), "a missing row is no error")
	_, err = d.GetSlackAppSetup("T0ACME")
	assert.True(t, errors.Is(err, sql.ErrNoRows))
}
