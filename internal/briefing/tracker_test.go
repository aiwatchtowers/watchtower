package briefing

import (
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedJiraBriefing seeds a Jira account whose owner ("acc-me") has an
// assigned stale, blocked, overdue issue, an assigned high-priority one, a
// reported open one, and a selected board with an active sprint.
func seedJiraBriefing(t *testing.T, d *db.DB) {
	t.Helper()
	acct, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net", Enabled: true})
	require.NoError(t, err)
	require.NoError(t, d.UpsertJiraBoard(db.JiraBoard{AccountID: acct, ID: 7, Name: "Core board", ProjectKey: "ABC"}))
	require.NoError(t, d.SetJiraBoardSelected(acct, 7, true))
	require.NoError(t, d.UpsertJiraSprint(db.JiraSprint{AccountID: acct, ID: 70, BoardID: 7, Name: "Sprint 12", State: "active",
		StartDate: "2020-01-01T00:00:00.000Z", EndDate: "2020-01-14T00:00:00.000Z"}))
	seed := func(i db.JiraIssue) {
		i.AccountID, i.ProjectKey, i.Labels, i.Components = acct, "ABC", `[]`, `[]`
		i.CreatedAt, i.SyncedAt = "2026-04-01T00:00:00.000Z", "2026-04-01T12:00:00Z"
		require.NoError(t, d.UpsertJiraIssue(i))
	}
	seed(db.JiraIssue{Key: "ABC-1", ID: "1", Summary: "Stuck migration", Status: "Blocked", StatusCategory: "in_progress",
		StatusCategoryChangedAt: "2020-02-01T00:00:00.000Z", Priority: "Medium", DueDate: "2020-03-01",
		SprintID: 70, SprintName: "Sprint 12", AssigneeAccountID: "acc-me", UpdatedAt: "2026-04-02T00:00:00.000Z"})
	seed(db.JiraIssue{Key: "ABC-2", ID: "2", Summary: "Ship the API", Status: "To Do", StatusCategory: "todo",
		Priority: "Highest", DueDate: "2099-01-01", SprintID: 70, SprintName: "Sprint 12", AssigneeAccountID: "acc-me",
		UpdatedAt: "2026-04-01T00:00:00.000Z"})
	seed(db.JiraIssue{Key: "ABC-3", ID: "3", Summary: "Review the doc", Status: "In Review", StatusCategory: "in_progress",
		ReporterAccountID: "acc-me", AssigneeAccountID: "acc-other", UpdatedAt: "2026-04-03T00:00:00.000Z"})
	seed(db.JiraIssue{Key: "ABC-4", ID: "4", Summary: "Closed", Status: "Done", StatusCategory: "done",
		SprintID: 70, AssigneeAccountID: "acc-me", UpdatedAt: "2026-04-03T00:00:00.000Z"})
}

// jiraBriefingWant is the Jira block rendered by the pre-Linear code for
// seedJiraBriefing (captured from it): moving the reads to tracker_issues
// must not change one byte of it.
const jiraBriefingWant = `=== MY JIRA ISSUES ===
- [ABC-2 status=To Do priority=Highest sprint="Sprint 12" due=2099-01-01] Ship the API
- [ABC-1 status=Blocked priority=Medium sprint="Sprint 12" OVERDUE:2020-03-01] Stuck migration

=== AWAITING MY INPUT ===
Reported by you (still open):
- [ABC-3 status=In Review] Review the doc
Blocked (assigned to you):
- [ABC-1 status=Blocked priority=Medium sprint="Sprint 12" OVERDUE:2020-03-01] Stuck migration

=== SPRINT PROGRESS ===
[Core board] Sprint "Sprint 12": 3 total (1 done, 1 in progress, 1 todo), 0 days left

=== STALE JIRA ISSUES (in_progress >7 days) ===
- [ABC-1 status=Blocked priority=Medium sprint="Sprint 12" OVERDUE:2020-03-01] Stuck migration

=== OVERDUE JIRA ISSUES ===
- [ABC-1 status=Blocked priority=Medium sprint="Sprint 12" OVERDUE:2020-03-01] Stuck migration`

func TestGatherJiraContext_JiraOutputUnchanged(t *testing.T) {
	database := testDB(t)
	seedJiraBriefing(t, database)
	cfg := jiraTestConfig()
	cfg.Linear.Enabled = true // no Linear data: the Jira block alone
	pipe := New(database, cfg, &mockGenerator{}, discardLogger())
	got := pipe.gatherJiraContext(db.Owner{ID: "jira:acc-me", Source: db.OwnerSourceJira, JiraAccountID: "acc-me"})
	assert.Equal(t, jiraBriefingWant, got)
}

func seedLinearBriefing(t *testing.T, d *db.DB) {
	t.Helper()
	la, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearTeams(la, []db.LinearTeam{{ID: "t-1", Key: "ENG", Name: "Eng"}}, nil))
	now := time.Now().UTC()
	require.NoError(t, d.UpsertLinearCycles([]db.LinearCycle{{AccountID: la, ID: "c-1", TeamID: "t-1", Number: 5,
		StartsAt: now.AddDate(0, 0, -2).Format(time.RFC3339), EndsAt: now.Add(60 * time.Hour).Format(time.RFC3339)}}))
	issue := func(i db.LinearIssue) {
		i.AccountID, i.TeamID, i.TeamKey = la, "t-1", "ENG"
		require.NoError(t, d.UpsertLinearIssue(i))
	}
	issue(db.LinearIssue{ID: "l-1", Key: "ENG-1", Title: "Linear stuck", StateName: "In Progress", StatusCategory: "in_progress",
		StateChangedAt: "2020-02-01T00:00:00.000Z", Priority: 2, DueDate: "2020-03-01", CycleID: "c-1",
		AssigneeID: "lin-me", UpdatedAt: "2026-04-02T00:00:00.000Z"})
	issue(db.LinearIssue{ID: "l-2", Key: "ENG-2", Title: "Blocker", StateName: "Todo", StatusCategory: "todo",
		AssigneeID: "lin-other", CreatorID: "lin-me", UpdatedAt: "2026-04-03T00:00:00.000Z"})
	require.NoError(t, d.ReplaceLinearRelations(la, "l-2", []db.LinearRelation{{ID: "r-1", RelatedIssueID: "l-1", Type: "blocks"}}))
}

// A Linear-only owner (Jira off) gets the same sections, headed for Linear,
// governed by the same Jira feature toggles.
func TestGatherJiraContext_LinearOnly(t *testing.T) {
	database := testDB(t)
	seedLinearBriefing(t, database)
	cfg := jiraTestConfig()
	cfg.Jira.Enabled = false
	cfg.Linear = config.LinearConfig{Enabled: true}
	pipe := New(database, cfg, &mockGenerator{}, discardLogger())
	owner := db.Owner{ID: "linear:lin-me", Source: db.OwnerSourceLinear, LinearUserIDs: []string{"lin-me"}}
	got := pipe.gatherJiraContext(owner)

	assert.Contains(t, got, "=== MY LINEAR ISSUES ===\n- [ENG-1 status=In Progress priority=High sprint=\"Cycle 5\" OVERDUE:2020-03-01] Linear stuck")
	assert.Contains(t, got, "=== AWAITING MY INPUT (LINEAR) ===\nReported by you (still open):\n- [ENG-2 status=Todo] Blocker")
	assert.Contains(t, got, "Blocked (assigned to you):\n- [ENG-1", "an incoming blocks relation from an open issue")
	assert.Contains(t, got, "=== CYCLE PROGRESS ===\n[ENG] \"Cycle 5\": 1 total (0 done, 1 in progress, 0 todo), 3 days left")
	assert.Contains(t, got, "=== STALE LINEAR ISSUES (in_progress >7 days) ===")
	assert.Contains(t, got, "=== OVERDUE LINEAR ISSUES ===")
	assert.NotContains(t, got, "JIRA")

	// The Jira toggles govern Linear too.
	cfg.Jira.Features = config.JiraFeatureToggles{}
	got = pipe.gatherJiraContext(owner)
	assert.NotContains(t, got, "MY LINEAR ISSUES")
	assert.NotContains(t, got, "CYCLE PROGRESS")
	assert.Contains(t, got, "STALE LINEAR ISSUES", "stale/overdue are always on, like Jira's")

	// Linear off: nothing.
	cfg.Linear.Enabled = false
	assert.Equal(t, "", pipe.gatherJiraContext(owner))
}

// Both trackers: one merged picture, Jira first, its block unchanged.
func TestGatherJiraContext_BothTrackers(t *testing.T) {
	database := testDB(t)
	seedJiraBriefing(t, database)
	seedLinearBriefing(t, database)
	cfg := jiraTestConfig()
	cfg.Linear.Enabled = true
	pipe := New(database, cfg, &mockGenerator{}, discardLogger())
	got := pipe.gatherJiraContext(db.Owner{ID: "jira:acc-me", JiraAccountID: "acc-me", LinearUserIDs: []string{"lin-me"}})
	require.True(t, strings.HasPrefix(got, jiraBriefingWant+"\n\n=== MY LINEAR ISSUES ==="), got)
}
