package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLinearIssue_UpsertKeepsSlackIDsAndFindsPreviousKey(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1", Email: "a@example.com", DisplayName: "A"}}))
	_, err := d.Exec(`UPDATE linear_user_map SET slack_user_id='1:U1' WHERE linear_user_id='u-1'`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: id, ID: "i-1", Key: "ENG-12", AssigneeID: "u-1", StatusCategory: "todo", Labels: []string{"Bug"}}))
	n, err := d.BackfillLinearSlackIDs(id)
	require.NoError(t, err)
	assert.Equal(t, int64(1), n)
	// Team move: same UUID, new key, old key remembered; the Slack id survives the upsert.
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: id, ID: "i-1", Key: "OPS-40", PreviousKeys: []string{"ENG-12"}, AssigneeID: "u-1", StatusCategory: "todo"}))
	got, err := d.GetLinearIssueByKey("ENG-12")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "OPS-40", got[0].Key)
	var slack string
	require.NoError(t, d.QueryRow(`SELECT assignee_slack_id FROM linear_issues WHERE id='i-1'`).Scan(&slack))
	assert.Equal(t, "1:U1", slack)
}

func TestLinearUsers_UpsertNeverClearsMapping(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1", Email: "a@example.com"}}))
	_, err := d.Exec(`UPDATE linear_user_map SET slack_user_id='1:U1', match_method='email' WHERE linear_user_id='u-1'`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1", Email: "a2@example.com", DisplayName: "A"}}))
	var slack, email string
	require.NoError(t, d.QueryRow(`SELECT slack_user_id, email FROM linear_user_map WHERE linear_user_id='u-1'`).Scan(&slack, &email))
	assert.Equal(t, "1:U1", slack)
	assert.Equal(t, "a2@example.com", email)
}

func TestLinearRelations_Replace(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.ReplaceLinearRelations(id, "i-1", []LinearRelation{{ID: "r-1", RelatedIssueID: "i-2", Type: "blocks"}}))
	require.NoError(t, d.ReplaceLinearRelations(id, "i-1", nil))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_relations`).Scan(&n))
	assert.Zero(t, n)
}

func TestLinearIssue_CreatorChangeResetsSlackID(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1"}}))
	_, err := d.Exec(`UPDATE linear_user_map SET slack_user_id='1:U1' WHERE linear_user_id='u-1'`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: id, ID: "i-1", Key: "ENG-1", CreatorID: "u-1"}))
	_, err = d.BackfillLinearSlackIDs(id)
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: id, ID: "i-1", Key: "ENG-1", CreatorID: "u-2"}))
	var slack string
	require.NoError(t, d.QueryRow(`SELECT creator_slack_id FROM linear_issues WHERE id='i-1'`).Scan(&slack))
	assert.Empty(t, slack)
}

func TestLinearBulkUpserts(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.UpsertLinearComment(LinearComment{AccountID: id, ID: "c-1", IssueID: "i-1", BodyText: "a"}))
	require.NoError(t, d.UpsertLinearComment(LinearComment{AccountID: id, ID: "c-1", IssueID: "i-1", BodyText: "b", MentionedUserIDs: []string{"u-1"}}))
	require.NoError(t, d.UpsertLinearHistory([]LinearHistoryEntry{{AccountID: id, ID: "h-1", Field: "status", IssueID: "i-1"}, {AccountID: id, ID: "h-1", Field: "assignee", IssueID: "i-1"}}))
	require.NoError(t, d.UpsertLinearCycles([]LinearCycle{{AccountID: id, ID: "cy-1", Number: 3}}))
	require.NoError(t, d.UpsertLinearProjects([]LinearProject{{AccountID: id, ID: "p-1", Name: "P"}}))
	for table, want := range map[string]int{"linear_comments": 1, "linear_issue_history": 2, "linear_cycles": 1, "linear_projects": 1} {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM `+table).Scan(&n))
		assert.Equal(t, want, n, table)
	}
}

func TestKnownLinearIssueIDs_ScopedToAccount(t *testing.T) {
	d := openTestDB(t)
	a, _ := d.CreateLinearAccount("a")
	b, _ := d.CreateLinearAccount("b")
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: a, ID: "i-1", Key: "ENG-1", StatusCategory: "todo"}))
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: b, ID: "i-2", Key: "ENG-2", StatusCategory: "todo"}))
	got, err := d.KnownLinearIssueIDs(a, []string{"i-2", "i-1", "i-3"})
	require.NoError(t, err)
	assert.Equal(t, []string{"i-1"}, got)
}
