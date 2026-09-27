package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedLookupIssue(t *testing.T, d *DB, accountID int64, key string) {
	t.Helper()
	require.NoError(t, d.UpsertJiraIssue(JiraIssue{AccountID: accountID, Key: key, ID: key, ProjectKey: "ABC",
		Summary: "s", Labels: "[]", Components: "[]", FixVersions: "[]", BoardID: 7}))
}

func TestGetJiraIssue_ByCompositeKey(t *testing.T) {
	d := openTestDB(t)
	a1, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://one"})
	require.NoError(t, err)
	a2, err := d.CreateJiraAccount(JiraAccount{CloudID: "c2", SiteURL: "https://two"})
	require.NoError(t, err)
	seedLookupIssue(t, d, a1, "ABC-1")

	got, err := d.GetJiraIssue(a1, "ABC-1")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, 7, got.BoardID)

	missing, err := d.GetJiraIssue(a2, "ABC-1")
	require.NoError(t, err)
	assert.Nil(t, missing, "the same key on another site is a different row")
}

func TestJiraAccountIDsForIssueKey_OnlyEnabledLiveSites(t *testing.T) {
	d := openTestDB(t)
	a1, _ := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://one"})
	a2, _ := d.CreateJiraAccount(JiraAccount{CloudID: "c2", SiteURL: "https://two"})
	a3, _ := d.CreateJiraAccount(JiraAccount{CloudID: "c3", SiteURL: "https://three"})
	for _, a := range []int64{a1, a2, a3} {
		seedLookupIssue(t, d, a, "ABC-1")
	}
	require.NoError(t, d.SetJiraAccountEnabled(a2, false))
	require.NoError(t, d.SetJiraAccountRemoved(a3))

	ids, err := d.JiraAccountIDsForIssueKey("ABC-1")
	require.NoError(t, err)
	assert.Equal(t, []int64{a1}, ids)

	none, err := d.JiraAccountIDsForIssueKey("ZZZ-9")
	require.NoError(t, err)
	assert.Empty(t, none)
}
