package db

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedMixedTrackers(t *testing.T, d *DB) {
	t.Helper()
	ja, err := d.CreateJiraAccount(JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_issues (account_id, key, id, project_key, summary, status, status_category,
		assignee_slack_id, priority, created_at, updated_at, synced_at, is_deleted)
		VALUES (?, 'ABC-1', '10001', 'ABC', 'Jira task', 'Blocked', 'in_progress', '1:U1', 'Highest',
		'2026-10-01T00:00:00.000Z', '2026-10-02T00:00:00.000Z', '2026-10-02T00:00:00Z', 0)`, ja)
	require.NoError(t, err)

	la, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearCycles([]LinearCycle{{AccountID: la, ID: "c-1", TeamID: "t-1", Number: 7}}))
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: la, ID: "i-1", Key: "ENG-1", TeamKey: "ENG",
		Title: "Linear task", StateName: "In Progress", StateType: "started", StatusCategory: "in_progress",
		Priority: 2, CycleID: "c-1", Labels: []string{"bug"}, UpdatedAt: "2026-10-03T00:00:00.000Z"}))
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: la, ID: "i-2", Key: "ENG-2", TeamKey: "ENG",
		Title: "Blocker", StateType: "unstarted", StatusCategory: "todo", UpdatedAt: "2026-10-01T00:00:00.000Z"}))
	require.NoError(t, d.ReplaceLinearRelations(la, "i-2", []LinearRelation{{ID: "r-1", RelatedIssueID: "i-1", Type: "blocks"}}))
	_, err = d.Exec(`UPDATE linear_issues SET assignee_slack_id = '1:U1' WHERE id = 'i-1'`)
	require.NoError(t, err)
}

func TestTrackerIssues_MergesBothTrackers(t *testing.T) {
	d := openTestDB(t)
	seedMixedTrackers(t, d)
	got, err := d.ListTrackerIssues(TrackerIssueFilter{AssigneeSlackID: "1:U1", OpenOnly: true})
	require.NoError(t, err)
	require.Len(t, got, 2)
	// priority_rank: Jira Highest = 1 sorts before Linear High = 2.
	assert.Equal(t, "jira", got[0].Tracker)
	assert.Equal(t, 1, got[0].PriorityRank)
	assert.True(t, got[0].IsBlocked) // Jira status-name rule
	assert.Equal(t, "https://acme.atlassian.net/browse/ABC-1", got[0].URL)

	assert.Equal(t, "linear", got[1].Tracker)
	assert.Equal(t, "High", got[1].Priority)
	assert.Equal(t, 2, got[1].PriorityRank)
	assert.Equal(t, "Cycle 7", got[1].IterationName)
	assert.True(t, got[1].IsBug)
	assert.True(t, got[1].IsBlocked) // incoming blocks relation from a not-done issue
}

func TestTrackerIssues_DoneBlockerDoesNotBlock(t *testing.T) {
	d := openTestDB(t)
	seedMixedTrackers(t, d)
	_, err := d.Exec(`UPDATE linear_issues SET status_category = 'done' WHERE id = 'i-2'`)
	require.NoError(t, err)
	got, err := d.ListTrackerIssues(TrackerIssueFilter{Tracker: "linear", AssigneeSlackID: "1:U1"})
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.False(t, got[0].IsBlocked)
}

func TestTrackerViews_AllQueryable(t *testing.T) {
	d := openTestDB(t)
	seedMixedTrackers(t, d)
	for _, v := range []string{"tracker_issues", "tracker_comments", "tracker_history", "tracker_iterations", "tracker_people", "tracker_accounts"} {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM (SELECT * FROM `+v+` LIMIT 1)`).Scan(&n), v)
	}
}

// The owner's-open-issues query must reach an index on both branches of the
// compound view; a plan regression fails here instead of slowing the daemon.
func TestTrackerIssues_OwnerOpenQueryUsesIndexes(t *testing.T) {
	d := openTestDB(t)
	rows, err := d.Query(`EXPLAIN QUERY PLAN SELECT key FROM tracker_issues
		WHERE assignee_slack_id = ? AND status_category != 'done' AND is_deleted = 0`, "1:U1")
	require.NoError(t, err)
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		plan = append(plan, detail)
	}
	joined := strings.Join(plan, "\n")
	assert.Contains(t, joined, "SEARCH ji USING INDEX idx_jira_issues_assignee_status", joined)
	assert.Contains(t, joined, "SEARCH li USING INDEX idx_linear_issues_assignee_status", joined)
}
