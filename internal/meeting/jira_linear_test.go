package meeting

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// seedMeetingTrackers stores, for attendee U1, an open Jira PROJ-1 and an open
// Linear ENG-5 that is blocked by an open ENG-6.
func seedMeetingTrackers(t *testing.T) *db.DB {
	t.Helper()
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
	return d
}

func trackersCfg(jira, linear bool) *config.Config {
	cfg := &config.Config{}
	cfg.Jira.Enabled, cfg.Linear.Enabled = jira, linear
	return cfg
}

// Each enabled tracker contributes its issues and only those: with Jira off
// the stored Jira issue is not read, with Linear off the Linear ones are not
// (Jira behaviour identical with Linear off). A Linear issue blocked by an
// open issue counts as blocked.
func TestGatherJiraMeetingContext_ReadsOnlyEnabledTrackers(t *testing.T) {
	d := seedMeetingTrackers(t)

	both := gatherJiraMeetingContext(d, trackersCfg(true, true), []string{"U1"})
	assert.Contains(t, both, "Open issues: 2 (0 SP), Blocked: 1")
	assert.Contains(t, both, "PROJ-1")
	assert.Contains(t, both, "[ENG-5 In Progress ] Linear work")

	linearOnly := gatherJiraMeetingContext(d, trackersCfg(false, true), []string{"U1"})
	assert.Contains(t, linearOnly, "Open issues: 1 (0 SP), Blocked: 1")
	assert.NotContains(t, linearOnly, "PROJ-1")

	jiraOnly := gatherJiraMeetingContext(d, trackersCfg(true, false), []string{"U1"})
	assert.Contains(t, jiraOnly, "Open issues: 1 (0 SP), Blocked: 0")
	assert.NotContains(t, jiraOnly, "ENG-5")

	assert.Empty(t, gatherJiraMeetingContext(d, trackersCfg(false, false), []string{"U1"}))
}

// The same key on Jira and on Linear is two issues: shared-issue detection
// keys by tracker, account and key, so neither issue's roles merge into the
// other's.
func TestGatherJiraMeetingContext_SameKeyOnBothTrackersStaysApart(t *testing.T) {
	d := db.OpenTestDB(t)
	jiraAcct := db.SeedTestJiraAccount(t, d)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{AccountID: jiraAcct, Key: "ABC-1", ProjectKey: "ABC", Summary: "Jira side",
		Status: "Open", StatusCategory: "todo", AssigneeSlackID: "U1", CreatedAt: "2026-04-01T00:00:00.000Z",
		UpdatedAt: "2026-04-01T00:00:00.000Z", SyncedAt: "2026-04-01T00:00:00Z"}))
	lin := db.SeedLinearTestAccount(t, d)
	db.SeedLinearTestIssue(t, d, db.LinearIssue{AccountID: lin, ID: "l1", Key: "ABC-1", TeamKey: "ABC", Title: "Linear side",
		StateName: "Todo", StatusCategory: "todo", UpdatedAt: "2026-04-02T00:00:00.000Z"}, "U2", "")

	got := gatherJiraMeetingContext(d, trackersCfg(true, true), []string{"U1", "U2"})
	assert.NotContains(t, got, "SHARED JIRA ISSUES", "U1 and U2 each work a different ABC-1")
	assert.Equal(t, 2, strings.Count(got, "[ABC-1 "), "both issues are listed under their own key")
}
