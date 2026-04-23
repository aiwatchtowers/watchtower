package jira

import (
	"fmt"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// --- Signal logic tests (no DB) ---

func TestComputeSignal_Overload(t *testing.T) {
	tests := []struct {
		name    string
		open    int
		overdue int
		blocked int
		msgs    int
	}{
		{"overdue > 2", 5, 3, 0, 50},
		{"blocked > 3", 5, 0, 4, 50},
		{"open > 15", 16, 0, 0, 50},
		{"all high", 20, 5, 5, 100},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, SignalOverload, computeSignal(tt.open, tt.overdue, tt.blocked, tt.msgs))
		})
	}
}

func TestComputeSignal_Watch(t *testing.T) {
	tests := []struct {
		name    string
		open    int
		overdue int
		blocked int
		msgs    int
	}{
		{"overdue = 1", 5, 1, 0, 50},
		{"blocked = 2", 5, 0, 2, 50},
		{"open = 11", 11, 0, 0, 50},
		{"overdue = 2", 5, 2, 0, 50},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, SignalWatch, computeSignal(tt.open, tt.overdue, tt.blocked, tt.msgs))
		})
	}
}

func TestComputeSignal_Low(t *testing.T) {
	assert.Equal(t, SignalLow, computeSignal(0, 0, 0, 0))
	assert.Equal(t, SignalLow, computeSignal(0, 0, 0, 4))
}

func TestComputeSignal_Normal(t *testing.T) {
	assert.Equal(t, SignalNormal, computeSignal(5, 0, 0, 20))
	assert.Equal(t, SignalNormal, computeSignal(0, 0, 0, 10)) // open=0 but msgs>=5 → normal, not low
	assert.Equal(t, SignalNormal, computeSignal(10, 0, 1, 50))
}

// --- Integration tests with in-memory DB ---

func openWorkloadTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

func enabledConfig() *config.Config {
	return &config.Config{
		Jira: config.JiraConfig{
			Enabled: true,
			Features: config.JiraFeatureToggles{
				TeamWorkload: true,
			},
		},
	}
}

func disabledConfig() *config.Config {
	return &config.Config{
		Jira: config.JiraConfig{
			Enabled: true,
			Features: config.JiraFeatureToggles{
				TeamWorkload: false,
			},
		},
	}
}

func TestWorkload_FeatureDisabled(t *testing.T) {
	d := openWorkloadTestDB(t)
	cfg := disabledConfig()

	result, err := ComputeTeamWorkload(d, cfg, time.Now().Add(-24*time.Hour), time.Now())
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestWorkload_JiraDisabled(t *testing.T) {
	d := openWorkloadTestDB(t)
	cfg := &config.Config{
		Jira: config.JiraConfig{
			Enabled: false,
		},
	}

	result, err := ComputeTeamWorkload(d, cfg, time.Now().Add(-24*time.Hour), time.Now())
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestWorkload_NilConfig(t *testing.T) {
	d := openWorkloadTestDB(t)
	result, err := ComputeTeamWorkload(d, nil, time.Now().Add(-24*time.Hour), time.Now())
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestWorkload_EmptyDB(t *testing.T) {
	d := openWorkloadTestDB(t)
	cfg := enabledConfig()

	result, err := ComputeTeamWorkload(d, cfg, time.Now().Add(-24*time.Hour), time.Now())
	assert.NoError(t, err)
	assert.Nil(t, result) // no jira rows → nil
}

func TestWorkload_WithJiraAndSlack(t *testing.T) {
	d := openWorkloadTestDB(t)
	cfg := enabledConfig()

	sp5 := 5.0

	// Insert Jira issues for two users.
	// U1: overload scenario (3 overdue).
	for i := 0; i < 3; i++ {
		require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
			Key: "P-" + string(rune('A'+i)), ProjectKey: "P", Summary: "Overdue task",
			Status: "Open", StatusCategory: "todo",
			AssigneeSlackID: "U1", AssigneeDisplayName: "Alice",
			StoryPoints: &sp5,
			DueDate:     "2020-01-01", // well in the past
			Labels:      `[]`, Components: `[]`,
			CreatedAt: "2026-03-01T00:00:00Z", UpdatedAt: "2026-04-01T00:00:00Z", SyncedAt: "now",
		}))
	}

	// U2: normal scenario — 2 open issues, no overdue.
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		Key: "P-X", ProjectKey: "P", Summary: "U2 task 1",
		Status: "In Progress", StatusCategory: "in_progress",
		AssigneeSlackID: "U2", AssigneeDisplayName: "Bob",
		Labels: `[]`, Components: `[]`,
		CreatedAt: "2026-04-01T00:00:00Z", UpdatedAt: "2026-04-01T00:00:00Z", SyncedAt: "now",
	}))
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		Key: "P-Y", ProjectKey: "P", Summary: "U2 task 2",
		Status: "To Do", StatusCategory: "todo",
		AssigneeSlackID: "U2", AssigneeDisplayName: "Bob",
		Labels: `[]`, Components: `[]`,
		CreatedAt: "2026-04-01T00:00:00Z", UpdatedAt: "2026-04-01T00:00:00Z", SyncedAt: "now",
	}))

	// Insert Slack messages for U2 (10 messages) to ensure not "low".
	from := time.Date(2026, 4, 8, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 4, 9, 0, 0, 0, 0, time.UTC)
	baseTS := from.Unix()
	for i := 0; i < 10; i++ {
		ts := float64(baseTS + int64(i*60)) // 1 minute apart
		tsStr := fmt.Sprintf("%d.%06d", int64(ts), i)
		require.NoError(t, d.UpsertMessage(db.Message{
			ChannelID: "C1", TS: tsStr, UserID: "U2", Text: "msg", RawJSON: "{}",
		}))
	}

	result, err := ComputeTeamWorkload(d, cfg, from, to)
	require.NoError(t, err)
	require.Len(t, result, 2)

	// U1 should be first (overload), U2 second (normal).
	assert.Equal(t, "U1", result[0].SlackUserID)
	assert.Equal(t, SignalOverload, result[0].Signal)
	assert.Equal(t, 3, result[0].OverdueCount)
	assert.Equal(t, 0, result[0].SlackMessageCount) // no messages inserted for U1

	assert.Equal(t, "U2", result[1].SlackUserID)
	assert.Equal(t, SignalNormal, result[1].Signal)
	assert.Equal(t, 10, result[1].SlackMessageCount)
	assert.Equal(t, 0.0, result[1].MeetingHours) // no calendar data
}

func TestWorkload_SortOrder(t *testing.T) {
	d := openWorkloadTestDB(t)
	cfg := enabledConfig()

	from := time.Date(2026, 4, 8, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 4, 9, 0, 0, 0, 0, time.UTC)

	// U1: normal (3 open, some slack messages)
	for i := 0; i < 3; i++ {
		require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
			Key: "N-" + string(rune('A'+i)), ProjectKey: "P", Summary: "Normal",
			Status: "Open", StatusCategory: "todo",
			AssigneeSlackID: "U1", AssigneeDisplayName: "Normal User",
			Labels: `[]`, Components: `[]`,
			CreatedAt: "2026-04-01T00:00:00Z", UpdatedAt: "2026-04-01T00:00:00Z", SyncedAt: "now",
		}))
	}
	// Insert messages for U1 to avoid "low" signal.
	baseTS := from.Unix()
	for i := 0; i < 10; i++ {
		tsStr := fmt.Sprintf("%d.%06d", baseTS+int64(i*60), i)
		require.NoError(t, d.UpsertMessage(db.Message{
			ChannelID: "C1", TS: tsStr, UserID: "U1", Text: "msg", RawJSON: "{}",
		}))
	}

	// U2: watch (1 overdue, 2 open)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		Key: "W-1", ProjectKey: "P", Summary: "Watch overdue",
		Status: "Open", StatusCategory: "todo",
		AssigneeSlackID: "U2", AssigneeDisplayName: "Watch User",
		DueDate: "2020-01-01",
		Labels:  `[]`, Components: `[]`,
		CreatedAt: "2026-04-01T00:00:00Z", UpdatedAt: "2026-04-01T00:00:00Z", SyncedAt: "now",
	}))
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		Key: "W-2", ProjectKey: "P", Summary: "Watch normal",
		Status: "Open", StatusCategory: "todo",
		AssigneeSlackID: "U2", AssigneeDisplayName: "Watch User",
		Labels: `[]`, Components: `[]`,
		CreatedAt: "2026-04-01T00:00:00Z", UpdatedAt: "2026-04-01T00:00:00Z", SyncedAt: "now",
	}))

	// U3: low (0 open, 0 messages)
	// Need at least one issue to appear in GetJiraTeamWorkload... but low means open==0.
	// GetJiraTeamWorkload only returns users with jira issues. A user with only done issues
	// still has open_issues=0. Let's add a done issue.
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		Key: "L-1", ProjectKey: "P", Summary: "Done task",
		Status: "Done", StatusCategory: "done",
		AssigneeSlackID: "U3", AssigneeDisplayName: "Low User",
		Labels: `[]`, Components: `[]`,
		CreatedAt: "2026-03-01T00:00:00Z", ResolvedAt: "2026-03-15T00:00:00Z",
		UpdatedAt: "2026-03-15T00:00:00Z", SyncedAt: "now",
	}))

	result, err := ComputeTeamWorkload(d, cfg, from, to)
	require.NoError(t, err)
	require.Len(t, result, 3)

	// Expected order: watch (U2), low (U3), normal (U1).
	assert.Equal(t, SignalWatch, result[0].Signal)
	assert.Equal(t, "U2", result[0].SlackUserID)

	assert.Equal(t, SignalLow, result[1].Signal)
	assert.Equal(t, "U3", result[1].SlackUserID)

	assert.Equal(t, SignalNormal, result[2].Signal)
	assert.Equal(t, "U1", result[2].SlackUserID)
}

func TestWorkload_WithMeetingHours(t *testing.T) {
	d := openWorkloadTestDB(t)
	cfg := enabledConfig()

	from := time.Date(2026, 4, 8, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 4, 9, 0, 0, 0, 0, time.UTC)

	// Create a user with Jira issues.
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		Key: "M-1", ProjectKey: "P", Summary: "Task",
		Status: "Open", StatusCategory: "todo",
		AssigneeSlackID: "U1", AssigneeDisplayName: "Alice",
		Labels: `[]`, Components: `[]`,
		CreatedAt: "2026-04-01T00:00:00Z", UpdatedAt: "2026-04-01T00:00:00Z", SyncedAt: "now",
	}))

	// Insert calendar data: calendar + event + attendee map.
	require.NoError(t, d.UpsertCalendar(db.CalendarCalendar{
		ID: "cal1", Name: "Work", IsPrimary: true, IsSelected: true, SyncedAt: "2026-04-08T00:00:00Z",
	}))
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID:         "evt1",
		CalendarID: "cal1",
		Title:      "Standup",
		StartTime:  "2026-04-08T09:00:00Z",
		EndTime:    "2026-04-08T10:00:00Z",
		Attendees:  `[{"email":"alice@example.com"}]`,
		RawJSON:    "{}",
	}))
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID:         "evt2",
		CalendarID: "cal1",
		Title:      "Sprint Review",
		StartTime:  "2026-04-08T14:00:00Z",
		EndTime:    "2026-04-08T15:30:00Z",
		Attendees:  `[{"email":"alice@example.com"},{"email":"bob@example.com"}]`,
		RawJSON:    "{}",
	}))
	require.NoError(t, d.UpsertAttendeeMap("alice@example.com", "U1"))

	// Add some slack messages to avoid "low".
	baseTS := from.Unix()
	for i := 0; i < 10; i++ {
		tsStr := fmt.Sprintf("%d.%06d", baseTS+int64(i*60), i)
		require.NoError(t, d.UpsertMessage(db.Message{
			ChannelID: "C1", TS: tsStr, UserID: "U1", Text: "msg", RawJSON: "{}",
		}))
	}

	result, err := ComputeTeamWorkload(d, cfg, from, to)
	require.NoError(t, err)
	require.Len(t, result, 1)

	e := result[0]
	assert.Equal(t, "U1", e.SlackUserID)
	assert.Equal(t, 10, e.SlackMessageCount)
	// evt1: 1 hour, evt2: 1.5 hours = 2.5 hours total
	assert.Equal(t, 2.5, e.MeetingHours)
	assert.Equal(t, SignalNormal, e.Signal)
}
