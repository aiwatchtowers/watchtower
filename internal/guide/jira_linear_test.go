package guide

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Linear plan 2: a Linear-only install (jira.enabled off, linear.enabled on,
// the my_issues toggle on) gets delivery stats from its Linear issues, and
// a person's Jira and Linear work add up.
func TestGatherJiraDelivery_CountsLinearIssues(t *testing.T) {
	database := testDB(t)
	jiraAcct := db.SeedTestJiraAccount(t, database)
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{
		AccountID: jiraAcct, Key: "PROJ-1", ID: "PROJ-1", ProjectKey: "PROJ", Summary: "Jira done",
		Status: "Done", StatusCategory: "done", AssigneeSlackID: "U123", ResolvedAt: "2026-04-03T00:00:00.000Z",
		CreatedAt: "2026-03-20T00:00:00.000Z", UpdatedAt: "2026-04-05T00:00:00.000Z", Labels: `[]`, Components: `["api"]`, SyncedAt: "2026-04-07",
	}))
	lin := db.SeedLinearTestAccount(t, database)
	est := 3.0
	db.SeedLinearTestIssue(t, database, db.LinearIssue{AccountID: lin, ID: "l1", Key: "ENG-1", TeamKey: "ENG",
		Title: "Linear done", StateName: "Done", StatusCategory: "done", Estimate: &est, Labels: []string{"importer"},
		CreatedAt: "2026-03-30T00:00:00.000Z", UpdatedAt: "2026-04-04T00:00:00.000Z", CompletedAt: "2026-04-04T00:00:00.000Z"}, "U123", "")
	db.SeedLinearTestIssue(t, database, db.LinearIssue{AccountID: lin, ID: "l2", Key: "ENG-2", TeamKey: "ENG",
		Title: "Linear open", StateName: "In Progress", StatusCategory: "in_progress", DueDate: "2026-04-01",
		UpdatedAt: "2026-04-06T00:00:00.000Z"}, "U123", "")

	cfg := &config.Config{}
	cfg.Linear.Enabled = true
	cfg.Jira.Features.MyIssuesInBriefing = true

	result, err := gatherJiraDelivery(database, cfg, "U123", "2026-04-01", "2026-04-08")
	require.NoError(t, err)
	assert.Contains(t, result, "Issues closed: 2")
	assert.Contains(t, result, "Story points: 3.0")
	assert.Contains(t, result, "Open issues: 1, Overdue: 1")
	assert.Contains(t, result, "Expertise: [api, importer]")
	assert.Contains(t, result, `Resolved ENG-1 "Linear done"`)
	assert.Contains(t, result, `Resolved PROJ-1 "Jira done"`)

	cfg.Jira.Features.MyIssuesInBriefing = false
	result, err = gatherJiraDelivery(database, cfg, "U123", "2026-04-01", "2026-04-08")
	require.NoError(t, err)
	assert.Empty(t, result, "the my_issues toggle governs both trackers")
}
