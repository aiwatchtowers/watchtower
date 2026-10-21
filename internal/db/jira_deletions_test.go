package db

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedJiraIssues stores one issue per key in the account's project.
func seedJiraIssues(t *testing.T, d *DB, accountID int64, project string, keys ...string) {
	t.Helper()
	issues := make([]JiraIssue, 0, len(keys))
	for _, k := range keys {
		issues = append(issues, JiraIssue{AccountID: accountID, Key: k, ID: k, ProjectKey: project, BoardID: 1,
			Summary: "summary " + k, Status: "To Do", StatusCategory: "new",
			Labels: "[]", Components: "[]", FixVersions: "[]", RawJSON: "{}", CustomFieldsJSON: "{}"})
	}
	require.NoError(t, d.UpsertJiraIssueBatch(issues, nil))
}

// jiraInboxItem stores an inbox item carrying a copy of an issue's text.
func jiraInboxItem(t *testing.T, d *DB, key, trigger, ts string) int64 {
	t.Helper()
	id, err := d.CreateInboxItem(InboxItem{ChannelID: key, MessageTS: ts, SenderUserID: "acc-a",
		TriggerType: trigger, Snippet: "issue text", Context: "ctx", RawText: "raw"})
	require.NoError(t, err)
	return id
}

func TestJiraProjectIssueKeys_Scope(t *testing.T) {
	d := openTestDB(t)
	a1 := SeedTestJiraAccount(t, d)
	a2 := SeedTestJiraAccount(t, d)
	seedJiraIssues(t, d, a1, "PROJ", "PROJ-2", "PROJ-1")
	seedJiraIssues(t, d, a1, "OTHER", "OTHER-9")
	seedJiraIssues(t, d, a2, "PROJ", "PROJ-7")

	keys, err := d.JiraProjectIssueKeys(a1, "PROJ")
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"PROJ-1", "PROJ-2"}, keys)
}

func TestDeleteJiraIssues_RemovesIssueAndChildren(t *testing.T) {
	d := openTestDB(t)
	a := SeedTestJiraAccount(t, d)
	seedJiraIssues(t, d, a, "PROJ", "PROJ-1", "PROJ-2", "PROJ-3")
	require.NoError(t, d.UpsertJiraComments([]JiraComment{
		{AccountID: a, IssueKey: "PROJ-1", ID: "c1", BodyText: "one"},
		{AccountID: a, IssueKey: "PROJ-1", ID: "c2", BodyText: "two"},
		{AccountID: a, IssueKey: "PROJ-2", ID: "c3", BodyText: "three"},
	}))
	require.NoError(t, d.ReplaceJiraIssueChangelogs(a, []JiraIssueHistory{
		{Key: "PROJ-1", UpdatedAt: "2026-10-01T00:00:00Z", Items: []JiraChangelogItem{{HistoryID: "h1", Field: "status", ChangedAt: "2026-10-01T00:00:00Z"}}},
		{Key: "PROJ-2", UpdatedAt: "2026-10-01T00:00:00Z", Items: []JiraChangelogItem{{HistoryID: "h2", Field: "status", ChangedAt: "2026-10-01T00:00:00Z"}}},
	}))
	for _, l := range []JiraIssueLink{
		{AccountID: a, ID: "l1", SourceKey: "PROJ-1", TargetKey: "PROJ-2", LinkType: "blocks"},
		{AccountID: a, ID: "l2", SourceKey: "PROJ-3", TargetKey: "PROJ-1", LinkType: "blocks"},
		{AccountID: a, ID: "l3", SourceKey: "PROJ-2", TargetKey: "PROJ-3", LinkType: "blocks"},
	} {
		require.NoError(t, d.UpsertJiraIssueLink(l))
	}

	n, err := d.DeleteJiraIssues(a, []string{"PROJ-1"})
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	assert.Equal(t, 0, countRows(t, d, `SELECT COUNT(*) FROM jira_issues WHERE key = 'PROJ-1'`))
	assert.Equal(t, 2, countRows(t, d, `SELECT COUNT(*) FROM jira_issues`))
	assert.Equal(t, 0, countRows(t, d, `SELECT COUNT(*) FROM jira_comments WHERE issue_key = 'PROJ-1'`))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_comments WHERE issue_key = 'PROJ-2'`))
	assert.Equal(t, 0, countRows(t, d, `SELECT COUNT(*) FROM jira_issue_changelog WHERE issue_key = 'PROJ-1'`))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_issue_changelog WHERE issue_key = 'PROJ-2'`))
	assert.Equal(t, 0, countRows(t, d, `SELECT COUNT(*) FROM jira_changelog_sync WHERE issue_key = 'PROJ-1'`))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_changelog_sync WHERE issue_key = 'PROJ-2'`))
	assert.Equal(t, 0, countRows(t, d, `SELECT COUNT(*) FROM jira_issue_links WHERE source_key = 'PROJ-1' OR target_key = 'PROJ-1'`))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_issue_links WHERE id = 'l3'`))

	_, ok := kbDirtyKeys(t, d)[fmt.Sprintf("jira|jira:%d:PROJ-1", a)]
	assert.True(t, ok, "the comment delete marks the issue's KB document: %v", kbDirtyKeys(t, d))
}

func TestDeleteJiraIssues_BlanksInboxCopies(t *testing.T) {
	d := openTestDB(t)
	a := SeedTestJiraAccount(t, d)
	seedJiraIssues(t, d, a, "PROJ", "PROJ-1", "PROJ-2")
	assigned := jiraInboxItem(t, d, "PROJ-1", "jira_assigned", "1")
	mention := jiraInboxItem(t, d, "PROJ-1", "jira_comment_mention", "2")
	other := jiraInboxItem(t, d, "PROJ-2", "jira_assigned", "3")
	slack, err := d.CreateInboxItem(InboxItem{ChannelID: "PROJ-1", MessageTS: "4", SenderUserID: "U1",
		TriggerType: "mention", Snippet: "slack text", Context: "ctx", RawText: "raw"})
	require.NoError(t, err)

	_, err = d.DeleteJiraIssues(a, []string{"PROJ-1"})
	require.NoError(t, err)

	copies := func(id int64) string {
		var s string
		require.NoError(t, d.QueryRow(`SELECT snippet || context || raw_text FROM inbox_items WHERE id = ?`, id).Scan(&s))
		return s
	}
	assert.Equal(t, "", copies(assigned))
	assert.Equal(t, "", copies(mention))
	assert.NotEqual(t, "", copies(other))
	assert.Equal(t, "slack textctxraw", copies(slack), "a non-Jira item is never touched")
}

func TestDeleteJiraIssues_OtherAccountKeepsKey(t *testing.T) {
	d := openTestDB(t)
	a1 := SeedTestJiraAccount(t, d)
	a2 := SeedTestJiraAccount(t, d)
	seedJiraIssues(t, d, a1, "PROJ", "PROJ-1", "PROJ-2")
	seedJiraIssues(t, d, a2, "PROJ", "PROJ-1", "PROJ-2")
	require.NoError(t, d.UpsertJiraComments([]JiraComment{
		{AccountID: a1, IssueKey: "PROJ-1", ID: "c1", BodyText: "one"},
		{AccountID: a2, IssueKey: "PROJ-1", ID: "c1", BodyText: "other site"},
	}))
	for _, a := range []int64{a1, a2} {
		require.NoError(t, d.ReplaceJiraIssueChangelogs(a, []JiraIssueHistory{
			{Key: "PROJ-1", UpdatedAt: "2026-10-01T00:00:00Z", Items: []JiraChangelogItem{{HistoryID: "h1", Field: "status", ChangedAt: "2026-10-01T00:00:00Z"}}},
		}))
		require.NoError(t, d.UpsertJiraIssueLink(JiraIssueLink{AccountID: a, ID: "l1", SourceKey: "PROJ-1", TargetKey: "PROJ-2", LinkType: "blocks"}))
	}
	item := jiraInboxItem(t, d, "PROJ-1", "jira_assigned", "1")

	n, err := d.DeleteJiraIssues(a1, []string{"PROJ-1"})
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_issues WHERE account_id = ? AND key = 'PROJ-1'`, a2))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_comments WHERE account_id = ?`, a2))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_issue_changelog WHERE account_id = ? AND issue_key = 'PROJ-1'`, a2))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_changelog_sync WHERE account_id = ? AND issue_key = 'PROJ-1'`, a2))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_issue_links WHERE account_id = ? AND id = 'l1'`, a2))
	assert.Equal(t, 0, countRows(t, d, `SELECT COUNT(*) FROM jira_issue_changelog WHERE account_id = ?`, a1))
	assert.Equal(t, 0, countRows(t, d, `SELECT COUNT(*) FROM jira_changelog_sync WHERE account_id = ?`, a1))
	assert.Equal(t, 0, countRows(t, d, `SELECT COUNT(*) FROM jira_issue_links WHERE account_id = ?`, a1))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM inbox_items WHERE id = ? AND snippet != ''`, item),
		"the bare-key inbox item may belong to the other account's live issue")
}

// More keys than one IN chunk (500): every chunk is deleted in the one
// transaction, and the issue past the list is kept.
func TestDeleteJiraIssues_AcrossChunks(t *testing.T) {
	d := openTestDB(t)
	a := SeedTestJiraAccount(t, d)
	keys := make([]string, 1201)
	for i := range keys {
		keys[i] = fmt.Sprintf("PROJ-%d", i+1)
	}
	seedJiraIssues(t, d, a, "PROJ", keys...)
	comments := make([]JiraComment, 0, len(keys))
	for i, k := range keys {
		comments = append(comments, JiraComment{AccountID: a, IssueKey: k, ID: fmt.Sprintf("c%d", i), BodyText: "x"})
	}
	require.NoError(t, d.UpsertJiraComments(comments))

	n, err := d.DeleteJiraIssues(a, keys[:1200])
	require.NoError(t, err)
	assert.Equal(t, 1200, n)
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_issues WHERE account_id = ?`, a))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_issues WHERE key = 'PROJ-1201'`))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM jira_comments WHERE account_id = ?`, a))
}

func TestDeleteJiraIssues_Empty(t *testing.T) {
	d := openTestDB(t)
	n, err := d.DeleteJiraIssues(1, nil)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
}
