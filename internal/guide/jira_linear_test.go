package guide

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// seedDeliveryTrackers stores one resolved Jira issue (component api) and, on
// Linear, one resolved issue (estimate 3, label importer) and one overdue open
// issue, all assigned to U123.
func seedDeliveryTrackers(t *testing.T) *db.DB {
	t.Helper()
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
	return database
}

func deliveryCfg(jira, linear, toggle bool) *config.Config {
	cfg := &config.Config{}
	cfg.Jira.Enabled, cfg.Linear.Enabled = jira, linear
	cfg.Jira.Features.MyIssuesInBriefing = toggle
	return cfg
}

// Both trackers on: a person's Jira and Linear work add up.
func TestGatherJiraDelivery_CountsBothTrackers(t *testing.T) {
	database := seedDeliveryTrackers(t)
	result, err := gatherJiraDelivery(database, deliveryCfg(true, true, true), "U123", "2026-04-01", "2026-04-08")
	require.NoError(t, err)
	assert.Contains(t, result, "Issues closed: 2")
	assert.Contains(t, result, "Story points: 3.0")
	assert.Contains(t, result, "Open issues: 1, Overdue: 1")
	assert.Contains(t, result, "Expertise: [api, importer]")
	assert.Contains(t, result, `Resolved ENG-1 "Linear done"`)
	assert.Contains(t, result, `Resolved PROJ-1 "Jira done"`)
}

// Only enabled trackers count: Linear-only ignores the stored Jira issue and
// its components; Jira-only ignores the stored Linear issues (Jira behaviour
// identical with Linear off). The my_issues toggle governs both.
func TestGatherJiraDelivery_CountsOnlyEnabledTrackers(t *testing.T) {
	database := seedDeliveryTrackers(t)

	linearOnly, err := gatherJiraDelivery(database, deliveryCfg(false, true, true), "U123", "2026-04-01", "2026-04-08")
	require.NoError(t, err)
	assert.Contains(t, linearOnly, "Issues closed: 1")
	assert.Contains(t, linearOnly, "Expertise: [importer]")
	assert.NotContains(t, linearOnly, "PROJ-1")

	jiraOnly, err := gatherJiraDelivery(database, deliveryCfg(true, false, true), "U123", "2026-04-01", "2026-04-08")
	require.NoError(t, err)
	assert.Contains(t, jiraOnly, "Issues closed: 1")
	assert.Contains(t, jiraOnly, "Story points: 0.0")
	assert.Contains(t, jiraOnly, "Expertise: [api]")
	assert.NotContains(t, jiraOnly, "ENG-")
	assert.NotContains(t, jiraOnly, "Open issues: 1")

	off, err := gatherJiraDelivery(database, deliveryCfg(true, true, false), "U123", "2026-04-01", "2026-04-08")
	require.NoError(t, err)
	assert.Empty(t, off)
}
