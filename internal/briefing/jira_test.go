package briefing

import (
	"io"
	"log"
	"slices"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func jiraTestConfig() *config.Config {
	return &config.Config{
		Digest:   config.DigestConfig{Enabled: true, Language: "English"},
		Briefing: config.BriefingConfig{Enabled: true, Hour: 8},
		Jira: config.JiraConfig{
			Enabled: true,
			Features: config.JiraFeatureToggles{
				MyIssuesInBriefing: true,
				AwaitingMyInput:    true,
				IterationProgress:  true,
			},
		},
	}
}

func discardLogger() *log.Logger { return log.New(io.Discard, "", 0) }

// --- gatherJiraContext ---

func TestGatherJiraContext_Disabled(t *testing.T) {
	database := testDB(t)
	cfg := jiraTestConfig()
	cfg.Jira.Enabled = false

	pipe := New(database, cfg, &mockGenerator{}, discardLogger())
	result := pipe.gatherJiraContext(db.Owner{ID: "U001", SlackUserID: "U001"})
	assert.Equal(t, "", result)
}

func TestGatherJiraContext_EmptyData(t *testing.T) {
	database := testDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))

	cfg := jiraTestConfig()
	pipe := New(database, cfg, &mockGenerator{}, discardLogger())
	result := pipe.gatherJiraContext(db.Owner{ID: "U001", SlackUserID: "U001"})
	assert.Equal(t, "", result)
}

// Owner-scoped Jira context never matches on an empty key: assignee/reporter
// columns default to the empty string, so an owner without that identity must see none of
// the unmapped issues that belong to someone else. A known Jira account id
// wins over the Slack bridge.
func TestGatherJiraContext_OwnerIdentityScoping(t *testing.T) {
	database := testDB(t)
	_, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", Enabled: true})
	require.NoError(t, err)
	seed := func(key, status, statusCat string, i db.JiraIssue) {
		i.AccountID, i.Key, i.ProjectKey, i.Summary = 1, key, "P", "Summary "+key
		i.Status, i.StatusCategory, i.Priority = status, statusCat, "High"
		i.Labels, i.Components = `[]`, `[]`
		i.CreatedAt, i.UpdatedAt, i.SyncedAt = "2026-04-01T00:00:00Z", "2026-04-01T12:00:00Z", "2026-04-01T12:00:00Z"
		require.NoError(t, database.UpsertJiraIssue(i))
	}
	// Someone else's issues, unmapped to Slack (both *_slack_id are '').
	seed("OTHER-1", "In Progress", "in_progress", db.JiraIssue{AssigneeAccountID: "acc-other", ReporterAccountID: "acc-other"})
	seed("OTHER-2", "To Do", "todo", db.JiraIssue{ReporterAccountID: "acc-other"})
	// The Jira owner's: assigned to them, and reported by them.
	seed("MINE-1", "In Progress", "in_progress", db.JiraIssue{AssigneeAccountID: "acc-me"})
	seed("MINE-2", "To Do", "todo", db.JiraIssue{AssigneeAccountID: "acc-other", ReporterAccountID: "acc-me"})
	// The Slack owner's, mapped through the Slack bridge only.
	seed("SLACK-1", "In Progress", "in_progress", db.JiraIssue{AssigneeAccountID: "acc-x", AssigneeSlackID: "1:U001"})

	all := []string{"OTHER-1", "OTHER-2", "MINE-1", "MINE-2", "SLACK-1"}
	cases := []struct {
		name  string
		owner db.Owner
		want  []string
	}{
		{"google-only owner", db.Owner{ID: "google:me@x.com", Source: db.OwnerSourceGoogle, Email: "me@x.com"}, nil},
		{"jira-only owner", db.Owner{ID: "jira:acc-me", Source: db.OwnerSourceJira, JiraAccountID: "acc-me"}, []string{"MINE-1", "MINE-2"}},
		{"slack owner without jira id", db.Owner{ID: "1:U001", Source: db.OwnerSourceSlack, SlackUserID: "1:U001"}, []string{"SLACK-1"}},
	}
	pipe := New(database, jiraTestConfig(), &mockGenerator{}, discardLogger())
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			result := pipe.gatherJiraContext(tc.owner)
			for _, key := range all {
				if slices.Contains(tc.want, key) {
					assert.Contains(t, result, key)
				} else {
					assert.NotContains(t, result, key)
				}
			}
		})
	}
}

// --- formatMyIssues ---

func TestFormatMyIssues_Empty(t *testing.T) {
	result := formatMyIssues(nil)
	assert.Equal(t, "", result)
}

func TestFormatMyIssues_WithIssues(t *testing.T) {
	issues := []db.JiraIssue{
		{Key: "PROJ-1", Summary: "Fix login bug", Status: "In Progress", StatusCategory: "in_progress", Priority: "High"},
		{Key: "PROJ-2", Summary: "Add tests", Status: "To Do", StatusCategory: "todo", Priority: "Medium"},
	}
	result := formatMyIssues(issues)
	assert.Contains(t, result, "PROJ-1")
	assert.Contains(t, result, "Fix login bug")
	assert.Contains(t, result, "PROJ-2")
	assert.Contains(t, result, "Add tests")
}

// --- stale detection ---

func TestGatherStaleAndOverdue_StaleIssue(t *testing.T) {
	now := time.Date(2026, 4, 8, 12, 0, 0, 0, time.UTC)
	// Changed 10 days ago — should be stale.
	changedAt := now.AddDate(0, 0, -10).Format(time.RFC3339)

	issues := []db.JiraIssue{
		{
			Key:                     "PROJ-10",
			Summary:                 "Stale feature",
			Status:                  "In Progress",
			StatusCategory:          "in_progress",
			StatusCategoryChangedAt: changedAt,
		},
	}

	result := gatherStaleAndOverdueAt(issues, now, discardLogger())
	assert.Contains(t, result, "STALE JIRA ISSUES")
	assert.Contains(t, result, "PROJ-10")
}

func TestGatherStaleAndOverdue_NotStaleYet(t *testing.T) {
	now := time.Date(2026, 4, 8, 12, 0, 0, 0, time.UTC)
	// Changed 3 days ago — not stale yet.
	changedAt := now.AddDate(0, 0, -3).Format(time.RFC3339)

	issues := []db.JiraIssue{
		{
			Key:                     "PROJ-11",
			Summary:                 "Recent work",
			Status:                  "In Progress",
			StatusCategory:          "in_progress",
			StatusCategoryChangedAt: changedAt,
		},
	}

	result := gatherStaleAndOverdueAt(issues, now, discardLogger())
	assert.NotContains(t, result, "STALE")
	assert.NotContains(t, result, "PROJ-11")
}

// --- overdue detection ---

func TestGatherStaleAndOverdue_OverdueIssue(t *testing.T) {
	now := time.Date(2026, 4, 8, 12, 0, 0, 0, time.UTC)

	issues := []db.JiraIssue{
		{
			Key:            "PROJ-20",
			Summary:        "Overdue task",
			Status:         "To Do",
			StatusCategory: "todo",
			DueDate:        "2026-04-01",
		},
	}

	result := gatherStaleAndOverdueAt(issues, now, discardLogger())
	assert.Contains(t, result, "OVERDUE JIRA ISSUES")
	assert.Contains(t, result, "PROJ-20")
}

func TestGatherStaleAndOverdue_OverdueWithTimestamp(t *testing.T) {
	// M2 fix: DueDate with time component should still work.
	now := time.Date(2026, 4, 8, 12, 0, 0, 0, time.UTC)

	issues := []db.JiraIssue{
		{
			Key:            "PROJ-21",
			Summary:        "Overdue with timestamp",
			Status:         "In Progress",
			StatusCategory: "in_progress",
			DueDate:        "2026-04-01T10:00:00Z",
		},
	}

	result := gatherStaleAndOverdueAt(issues, now, discardLogger())
	assert.Contains(t, result, "OVERDUE JIRA ISSUES")
	assert.Contains(t, result, "PROJ-21")
}

func TestGatherStaleAndOverdue_NotOverdue(t *testing.T) {
	now := time.Date(2026, 4, 8, 12, 0, 0, 0, time.UTC)

	issues := []db.JiraIssue{
		{
			Key:            "PROJ-22",
			Summary:        "Future task",
			Status:         "To Do",
			StatusCategory: "todo",
			DueDate:        "2026-04-15",
		},
	}

	result := gatherStaleAndOverdueAt(issues, now, discardLogger())
	assert.NotContains(t, result, "OVERDUE")
}

func TestGatherStaleAndOverdue_DoneNotOverdue(t *testing.T) {
	now := time.Date(2026, 4, 8, 12, 0, 0, 0, time.UTC)

	issues := []db.JiraIssue{
		{
			Key:            "PROJ-23",
			Summary:        "Done task with past due",
			Status:         "Done",
			StatusCategory: "done",
			DueDate:        "2026-04-01",
		},
	}

	result := gatherStaleAndOverdueAt(issues, now, discardLogger())
	assert.Equal(t, "", result)
}

func TestGatherStaleAndOverdue_EmptyIssues(t *testing.T) {
	now := time.Date(2026, 4, 8, 12, 0, 0, 0, time.UTC)
	result := gatherStaleAndOverdueAt(nil, now, discardLogger())
	assert.Equal(t, "", result)
}
