package meeting

import (
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
)

func enabledJiraConfig() *config.Config {
	return &config.Config{Jira: config.JiraConfig{Enabled: true}}
}

func disabledJiraConfig() *config.Config {
	return &config.Config{Jira: config.JiraConfig{Enabled: false}}
}

func TestDedupAttendeeIDs(t *testing.T) {
	idSet, ids := dedupAttendeeIDs([]string{"U1", "U2", "U1", "", "U3", "U2"})
	assert.Equal(t, []string{"U1", "U2", "U3"}, ids)
	assert.True(t, idSet["U1"])
	assert.True(t, idSet["U2"])
	assert.True(t, idSet["U3"])
	assert.False(t, idSet[""])
}

func TestDedupAttendeeIDs_Empty(t *testing.T) {
	idSet, ids := dedupAttendeeIDs(nil)
	assert.Empty(t, ids)
	assert.Empty(t, idSet)
}

func TestIsBlocked(t *testing.T) {
	cases := []struct {
		status string
		want   bool
	}{
		{"Blocked", true},
		{"BLOCKED", true},
		{"blocked by external", true},
		{"In Progress", false},
		{"Done", false},
		{"", false},
	}
	for _, tc := range cases {
		t.Run(tc.status, func(t *testing.T) {
			got := isBlocked(db.JiraIssue{Status: tc.status})
			assert.Equal(t, tc.want, got)
		})
	}
}

func TestIsOverdue(t *testing.T) {
	today := time.Date(2026, 4, 2, 0, 0, 0, 0, time.UTC)

	cases := []struct {
		name  string
		issue db.JiraIssue
		want  bool
	}{
		{"past due, not done", db.JiraIssue{DueDate: "2026-04-01", StatusCategory: "in progress"}, true},
		{"future due", db.JiraIssue{DueDate: "2026-04-10"}, false},
		{"due today is not overdue", db.JiraIssue{DueDate: "2026-04-02"}, false},
		{"past due but done", db.JiraIssue{DueDate: "2026-04-01", StatusCategory: "done"}, false},
		{"past due but DONE upper", db.JiraIssue{DueDate: "2026-04-01", StatusCategory: "DONE"}, false},
		{"no due date", db.JiraIssue{DueDate: ""}, false},
		{"malformed due date", db.JiraIssue{DueDate: "not a date"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, isOverdue(tc.issue, today))
		})
	}
}

func TestAttendeesHaveData(t *testing.T) {
	assert.False(t, attendeesHaveData(nil))
	assert.False(t, attendeesHaveData([]attendeeJira{{slackID: "U1"}}))
	assert.True(t, attendeesHaveData([]attendeeJira{{slackID: "U1", issues: []db.JiraIssue{{Key: "PROJ-1"}}}}))
}

func TestLookupDisplayName(t *testing.T) {
	attendees := []attendeeJira{
		{slackID: "U1", displayName: "Alice"},
		{slackID: "U2"}, // no displayName
	}
	assert.Equal(t, "Alice", lookupDisplayName(attendees, "U1"))
	assert.Equal(t, "U2", lookupDisplayName(attendees, "U2"), "fallback to slackID when no name")
	assert.Equal(t, "U99", lookupDisplayName(attendees, "U99"), "fallback for unknown id")
}

func TestIndexIssuesAndReporters_AddsReporterRole(t *testing.T) {
	attendees := []attendeeJira{
		{slackID: "U1", issues: []db.JiraIssue{
			{Key: "P-1", ReporterSlackID: "U2"},
		}},
	}
	idSet := map[string]bool{"U1": true, "U2": true}
	parts := map[string][]issueRole{
		"P-1": {{slackID: "U1", role: "assignee"}},
	}
	allIssues := indexIssuesAndReporters(attendees, idSet, parts)
	assert.Contains(t, allIssues, "P-1")

	// Reporter role added because U2 is also an attendee.
	roles := parts["P-1"]
	require := false
	for _, r := range roles {
		if r.role == "reporter" && r.slackID == "U2" {
			require = true
		}
	}
	assert.True(t, require, "reporter role should be appended for U2")
}

func TestIndexIssuesAndReporters_SkipsSelfReporter(t *testing.T) {
	// Reporter == assignee should not add a duplicate role.
	attendees := []attendeeJira{
		{slackID: "U1", issues: []db.JiraIssue{
			{Key: "P-1", ReporterSlackID: "U1"},
		}},
	}
	idSet := map[string]bool{"U1": true}
	parts := map[string][]issueRole{"P-1": {{slackID: "U1", role: "assignee"}}}

	indexIssuesAndReporters(attendees, idSet, parts)
	assert.Len(t, parts["P-1"], 1, "no duplicate reporter for self-reported issue")
}

func TestIndexIssuesAndReporters_SkipsNonAttendeeReporter(t *testing.T) {
	attendees := []attendeeJira{
		{slackID: "U1", issues: []db.JiraIssue{
			{Key: "P-1", ReporterSlackID: "U99"}, // U99 not an attendee
		}},
	}
	idSet := map[string]bool{"U1": true}
	parts := map[string][]issueRole{"P-1": {{slackID: "U1", role: "assignee"}}}

	indexIssuesAndReporters(attendees, idSet, parts)
	assert.Len(t, parts["P-1"], 1)
}

func TestFormatAttendeeSections_TruncatesIssueList(t *testing.T) {
	issues := make([]db.JiraIssue, 12)
	for i := range issues {
		issues[i] = db.JiraIssue{Key: "P-" + strings.Repeat("x", i+1), Status: "In Progress", Summary: "issue"}
	}
	attendees := []attendeeJira{
		{slackID: "U1", displayName: "Alice", issues: issues, totalSP: 4.5, blocked: 1, overdue: 2},
	}
	var sb strings.Builder
	formatAttendeeSections(&sb, attendees, time.Now())
	out := sb.String()
	assert.Contains(t, out, "@Alice (U1):")
	assert.Contains(t, out, "Open issues: 12")
	assert.Contains(t, out, "and 2 more issues")
}

func TestFormatAttendeeSections_FallbackToSlackIDName(t *testing.T) {
	attendees := []attendeeJira{
		{slackID: "U1", issues: []db.JiraIssue{{Key: "P-1", Summary: "x"}}},
	}
	var sb strings.Builder
	formatAttendeeSections(&sb, attendees, time.Now())
	assert.Contains(t, sb.String(), "@U1 (U1):")
}

func TestFormatSharedIssues(t *testing.T) {
	attendees := []attendeeJira{
		{slackID: "U1", displayName: "Alice"},
		{slackID: "U2", displayName: "Bob"},
	}
	allIssues := map[string]db.JiraIssue{
		"P-1": {Key: "P-1", Status: "In Progress", Summary: "Shared work"},
		"P-2": {Key: "P-2", Status: "Done", Summary: "Solo work"},
	}
	parts := map[string][]issueRole{
		"P-1": {{slackID: "U1", role: "assignee"}, {slackID: "U2", role: "reporter"}},
		"P-2": {{slackID: "U1", role: "assignee"}}, // single role → not shared
	}
	var sb strings.Builder
	formatSharedIssues(&sb, attendees, allIssues, parts)
	out := sb.String()
	assert.Contains(t, out, "SHARED JIRA ISSUES")
	assert.Contains(t, out, "P-1")
	assert.NotContains(t, out, "P-2")
	assert.Contains(t, out, "@Alice (assignee)")
	assert.Contains(t, out, "@Bob (reporter)")
}

func TestFormatSharedIssues_NoSharedNoOutput(t *testing.T) {
	var sb strings.Builder
	formatSharedIssues(&sb, nil, nil, nil)
	assert.Empty(t, sb.String())
}

func TestGatherJiraMeetingContext_Disabled(t *testing.T) {
	cfg := disabledJiraConfig()
	got, err := gatherJiraMeetingContext(nil, cfg, []string{"U1"})
	assert.NoError(t, err)
	assert.Empty(t, got)
}

func TestGatherJiraMeetingContext_NoAttendees(t *testing.T) {
	cfg := enabledJiraConfig()
	got, err := gatherJiraMeetingContext(nil, cfg, nil)
	assert.NoError(t, err)
	assert.Empty(t, got)
}

func TestGatherJiraMeetingContext_OnlyEmptyIDs(t *testing.T) {
	cfg := enabledJiraConfig()
	got, err := gatherJiraMeetingContext(nil, cfg, []string{"", ""})
	assert.NoError(t, err)
	assert.Empty(t, got)
}
