package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestReactionTrackerPrefixes_BothTrackers(t *testing.T) {
	d := openTestDB(t)
	ja, err := d.CreateJiraAccount(JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_sync_state (account_id, project_key) VALUES (?, 'OPS')`, ja)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_issues (account_id, key, id, project_key, summary, status, status_category,
		created_at, updated_at, synced_at, is_deleted)
		VALUES (?, 'ABC-1', '1', 'ABC', 's', 'Open', 'todo', '', '', '', 0)`, ja)
	require.NoError(t, err)

	live, err := d.CreateLinearAccount("live")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearTeams(live, []LinearTeam{{ID: "t1", Key: "ENG"}, {ID: "t2", Key: "OPS"}}, nil))
	off, err := d.CreateLinearAccount("off")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearTeams(off, []LinearTeam{{ID: "t3", Key: "OFF"}}, nil))
	require.NoError(t, d.SetLinearAccountEnabled(off, false))
	gone, err := d.CreateLinearAccount("gone")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearTeams(gone, []LinearTeam{{ID: "t4", Key: "GONE"}}, nil))
	require.NoError(t, d.SetLinearAccountRemoved(gone))

	got, err := d.ReactionTrackerPrefixes()
	require.NoError(t, err)
	assert.Equal(t, map[string]bool{"OPS": true, "ABC": true}, got.Jira)
	assert.Equal(t, map[string]bool{"ENG": true, "OPS": true}, got.Linear, "disabled and removed accounts' teams are not Linear keys")
}

// A removed or disabled Jira account keeps its rows but owns no prefix.
func TestReactionTrackerPrefixes_IgnoresRemovedAndDisabledJiraAccounts(t *testing.T) {
	d := openTestDB(t)
	for i, state := range []string{"removed", "disabled"} {
		ja, err := d.CreateJiraAccount(JiraAccount{CloudID: state, SiteURL: "https://" + state + ".example.com", SiteName: state})
		require.NoError(t, err)
		key := []string{"OLD", "OFF"}[i]
		_, err = d.Exec(`INSERT INTO jira_sync_state (account_id, project_key) VALUES (?, ?)`, ja, key)
		require.NoError(t, err)
		_, err = d.Exec(`INSERT INTO jira_issues (account_id, key, id, project_key, summary, status, status_category,
			created_at, updated_at, synced_at, is_deleted)
			VALUES (?, ? || '-1', ?, ?, 's', 'Open', 'todo', '', '', '', 0)`, ja, key, state, key)
		require.NoError(t, err)
		if state == "removed" {
			require.NoError(t, d.SetJiraAccountRemoved(ja))
		} else {
			require.NoError(t, d.SetJiraAccountEnabled(ja, false))
		}
	}
	got, err := d.ReactionTrackerPrefixes()
	require.NoError(t, err)
	assert.Empty(t, got.Jira)
}

func TestReactionTrackerPrefixes_Empty(t *testing.T) {
	got, err := openTestDB(t).ReactionTrackerPrefixes()
	require.NoError(t, err)
	assert.Empty(t, got.Jira)
	assert.Empty(t, got.Linear)
}

func TestRecentChannelTexts_NewestFirstSkipsDeletedAndOtherChannels(t *testing.T) {
	d := openTestDB(t)
	for _, m := range []struct {
		ch, ts, text string
		deleted      int
	}{
		{"1:C1", "100.1", "old ENG-1", 0},
		{"1:C1", "300.1", "new ABC-2", 0},
		{"1:C1", "200.1", "gone", 1},
		{"1:C1", "250.1", "", 0},
		{"1:C2", "400.1", "other", 0},
	} {
		_, err := d.Exec(`INSERT INTO messages (channel_id, ts, text, is_deleted) VALUES (?,?,?,?)`, m.ch, m.ts, m.text, m.deleted)
		require.NoError(t, err)
	}
	got, err := d.RecentChannelTexts("1:C1", 10)
	require.NoError(t, err)
	assert.Equal(t, []string{"new ABC-2", "old ENG-1"}, got)

	got, err = d.RecentChannelTexts("1:C1", 1)
	require.NoError(t, err)
	assert.Equal(t, []string{"new ABC-2"}, got)
}

func TestListReactionLinearTeams_SelectedOnEnabledAccounts(t *testing.T) {
	d := openTestDB(t)
	a1, err := d.CreateLinearAccount("one")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearTeams(a1, []LinearTeam{{ID: "t1", Key: "ENG"}, {ID: "t2", Key: "DES"}, {ID: "t3", Key: "MUTED"}},
		map[string]bool{"t1": true, "t2": true}))
	a2, err := d.CreateLinearAccount("two")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearTeams(a2, []LinearTeam{{ID: "t4", Key: "ENG"}}, map[string]bool{"t4": true}))
	off, err := d.CreateLinearAccount("off")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearTeams(off, []LinearTeam{{ID: "t5", Key: "OFF"}}, map[string]bool{"t5": true}))
	require.NoError(t, d.SetLinearAccountEnabled(off, false))

	got, err := d.ListReactionLinearTeams()
	require.NoError(t, err)
	assert.Equal(t, []ReactionLinearTeam{{a1, "DES"}, {a1, "ENG"}, {a2, "ENG"}}, got)
}
