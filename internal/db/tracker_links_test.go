package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Linear links of a track resolve to the issue under its current or a previous
// key, once per issue, and never through a Jira link or a deleted issue.
func TestGetLinearIssuesForTracks(t *testing.T) {
	d := openTestDB(t)
	acct := SeedLinearTestAccount(t, d)
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: acct, ID: "u1", Key: "OPS-3", PreviousKeys: []string{"ENG-7"},
		Title: "Moved", StateName: "Todo", StatusCategory: "todo", UpdatedAt: "2026-10-01T00:00:00.000Z"}))
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: acct, ID: "u2", Key: "ENG-9", Title: "Gone",
		UpdatedAt: "2026-10-01T00:00:00.000Z", IsDeleted: true}))
	t1, t2 := 1, 2
	for _, l := range []IssueSlackLink{
		{Tracker: "linear", IssueKey: "ENG-7", TrackID: &t1, LinkType: "track"},
		{Tracker: "linear", IssueKey: "OPS-3", TrackID: &t1, LinkType: "track"},
		{Tracker: "linear", IssueKey: "ENG-9", TrackID: &t1, LinkType: "track"},
		{Tracker: "jira", IssueKey: "OPS-3", TrackID: &t2, LinkType: "track"},
	} {
		require.NoError(t, d.UpsertIssueSlackLink(l))
	}

	got, err := d.GetLinearIssuesForTracks([]int{t1, t2})
	require.NoError(t, err)
	require.Len(t, got[t1], 1, "linked under two keys, listed once; the deleted issue is skipped")
	assert.Equal(t, "OPS-3", got[t1][0].Key)
	assert.Empty(t, got[t2], "a Jira link is not a Linear issue")
}
