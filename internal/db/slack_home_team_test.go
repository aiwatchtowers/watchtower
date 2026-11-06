package db

import (
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestSlackAccountHomeTeam_AccountOneUsesLegacyWorkspace(t *testing.T) {
	d := openTestDB(t)
	// The row was overwritten by a sign-in into another team; the frozen
	// legacy workspace snapshot still names the team its data came from.
	id, err := d.CreateSlackAccount(SlackAccount{TeamID: "T_OTHER", TeamName: "Other"})
	require.NoError(t, err)
	require.Equal(t, int64(1), id)
	require.NoError(t, d.UpsertWorkspace(Workspace{ID: "T_HOME", Name: "Acme"}))

	acct, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	home, err := d.SlackAccountHomeTeam(acct)
	require.NoError(t, err)
	require.Equal(t, SlackHomeTeam{ID: "T_HOME", Name: "Acme"}, home)
	require.True(t, home.Conflicts("T_OTHER"))
	require.False(t, home.Conflicts("T_HOME"))
}

func TestSlackAccountHomeTeam_OtherAccountsUseTheirRow(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertWorkspace(Workspace{ID: "T_HOME", Name: "Acme"}))
	_, err := d.CreateSlackAccount(SlackAccount{TeamID: "T_HOME"})
	require.NoError(t, err)
	id, err := d.CreateSlackAccount(SlackAccount{TeamID: "T_SECOND", TeamName: "Beta"})
	require.NoError(t, err)

	acct, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	home, err := d.SlackAccountHomeTeam(acct)
	require.NoError(t, err)
	require.Equal(t, SlackHomeTeam{ID: "T_SECOND", Name: "Beta"}, home)
}

func TestSlackAccountHomeTeam_NoTeamYetAcceptsAny(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	acct, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	home, err := d.SlackAccountHomeTeam(acct)
	require.NoError(t, err)
	require.Empty(t, home.ID)
	require.False(t, home.Conflicts("T_ANY"))
}

func TestSlackHomeTeam_EmptyTeamNeverConflicts(t *testing.T) {
	require.False(t, SlackHomeTeam{ID: "T_HOME"}.Conflicts(""))
}

func TestLatestSlackMessageTime(t *testing.T) {
	d := openTestDB(t)
	_, ok, err := d.LatestSlackMessageTime(1)
	require.NoError(t, err)
	require.False(t, ok)

	newest := time.Date(2026, 3, 5, 12, 0, 0, 0, time.UTC)
	for _, m := range []struct {
		ch string
		at time.Time
	}{
		{"1:C1", newest.Add(-48 * time.Hour)},
		{"1:C2", newest},
		{"2:C1", newest.Add(72 * time.Hour)}, // another account's newer message
		{"10:C1", newest.Add(96 * time.Hour)},
	} {
		_, err := d.Exec(`INSERT INTO messages (channel_id, ts, text) VALUES (?, ?, '')`,
			m.ch, formatSlackTS(m.at))
		require.NoError(t, err)
	}
	got, ok, err := d.LatestSlackMessageTime(1)
	require.NoError(t, err)
	require.True(t, ok)
	require.True(t, got.Equal(newest), "got %v", got)
}

func formatSlackTS(t time.Time) string {
	return strconv.FormatInt(t.Unix(), 10) + ".000100"
}
