package meeting

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Linear plan 2: an attendee's load comes from tracker_issues — open Jira and
// Linear issues alike — and a Linear issue blocked by an open issue counts as
// blocked. A Linear-only install (jira.enabled off) still gets the section.
func TestGatherJiraMeetingContext_IncludesLinearIssues(t *testing.T) {
	d := db.OpenTestDB(t)
	jiraAcct := db.SeedTestJiraAccount(t, d)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{AccountID: jiraAcct, Key: "PROJ-1", ProjectKey: "PROJ", Summary: "Jira work",
		Status: "In Progress", StatusCategory: "in_progress", AssigneeSlackID: "U1", AssigneeDisplayName: "Alice",
		CreatedAt: "2026-04-01T00:00:00.000Z", UpdatedAt: "2026-04-01T00:00:00.000Z", SyncedAt: "2026-04-01T00:00:00Z"}))
	lin := db.SeedLinearTestAccount(t, d)
	db.SeedLinearTestIssue(t, d, db.LinearIssue{AccountID: lin, ID: "l1", Key: "ENG-5", TeamKey: "ENG", Title: "Linear work",
		StateName: "In Progress", StatusCategory: "in_progress", AssigneeID: "lu1", AssigneeDisplayName: "Alice",
		UpdatedAt: "2026-04-02T00:00:00.000Z"}, "U1", "")
	db.SeedLinearTestIssue(t, d, db.LinearIssue{AccountID: lin, ID: "l2", Key: "ENG-6", TeamKey: "ENG", Title: "Blocker",
		StateName: "Todo", StatusCategory: "todo", UpdatedAt: "2026-04-02T00:00:00.000Z"}, "", "")
	require.NoError(t, d.ReplaceLinearRelations(lin, "l2", []db.LinearRelation{{ID: "r1", RelatedIssueID: "l1", Type: "blocks"}}))

	got := gatherJiraMeetingContext(d, &config.Config{Linear: config.LinearConfig{Enabled: true}}, []string{"U1"})
	assert.Contains(t, got, "Open issues: 2 (0 SP), Blocked: 1")
	assert.Contains(t, got, "PROJ-1")
	assert.Contains(t, got, "[ENG-5 In Progress ] Linear work")
}
