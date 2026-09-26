package dayplan

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

func gatherTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

func testPipeline(d *db.DB) *Pipeline {
	return &Pipeline{db: d}
}

// TestGatherTargets_OnlyActive seeds 3 targets (todo, in_progress, done) and
// verifies that gatherTargets returns only the 2 active ones.
func TestGatherTargets_OnlyActive(t *testing.T) {
	d := gatherTestDB(t)
	p := testPipeline(d)

	targets := []db.Target{
		{Text: "todo target", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"},
		{Text: "in_progress target", Status: "in_progress", Priority: "high", Ownership: "mine", SourceType: "manual"},
		{Text: "done target", Status: "done", Priority: "low", Ownership: "mine", SourceType: "manual"},
	}
	for _, tk := range targets {
		_, err := d.CreateTarget(tk)
		require.NoError(t, err)
	}

	got, err := p.gatherTargets()
	require.NoError(t, err)
	require.Len(t, got, 2, "expected 2 active targets (todo + in_progress)")

	statuses := map[string]bool{}
	for _, tk := range got {
		statuses[tk.Status] = true
	}
	require.True(t, statuses["todo"], "expected todo target in results")
	require.True(t, statuses["in_progress"], "expected in_progress target in results")
}

// TestGatherBriefing_FallbackYesterday seeds yesterday's briefing only and
// verifies that gatherBriefing(userID, today) returns yesterday's row.
func TestGatherBriefing_FallbackYesterday(t *testing.T) {
	d := gatherTestDB(t)
	p := testPipeline(d)

	today := time.Now().UTC().Format("2006-01-02")
	yesterday := time.Now().UTC().AddDate(0, 0, -1).Format("2006-01-02")

	_, err := d.UpsertBriefing(db.Briefing{
		WorkspaceID:  "W1",
		UserID:       "U1",
		Date:         yesterday,
		Role:         "engineer",
		Attention:    "[]",
		YourDay:      "[]",
		WhatHappened: "[]",
		TeamPulse:    "[]",
		Coaching:     "[]",
	})
	require.NoError(t, err)

	got := p.gatherBriefing("U1", today)
	require.NotNil(t, got, "expected fallback to yesterday's briefing")
	require.Equal(t, yesterday, got.Date)
	require.Equal(t, "U1", got.UserID)
}

// TestGatherCalendarEvents_Today seeds 1 event starting today at 10:00 and
// verifies gatherCalendarEvents(today) returns that event.
func TestGatherCalendarEvents_Today(t *testing.T) {
	d := gatherTestDB(t)
	p := testPipeline(d)

	today := time.Now().UTC().Format("2006-01-02")

	// Calendar events have a FK to calendar_calendars; insert a parent calendar first.
	require.NoError(t, d.UpsertCalendar(0, db.CalendarCalendar{
		ID:        "cal-001",
		Name:      "Primary",
		IsPrimary: true,
	}))

	ev := db.CalendarEvent{
		ID:         "evt-001",
		CalendarID: "cal-001",
		Title:      "Morning standup",
		StartTime:  today + "T10:00:00Z",
		EndTime:    today + "T10:30:00Z",
		Attendees:  "[]",
	}
	require.NoError(t, d.UpsertCalendarEvent(ev))

	got, err := p.gatherCalendarEvents(today)
	require.NoError(t, err)
	require.Len(t, got, 1, "expected 1 event for today")
	require.Equal(t, "evt-001", got[0].ID)
	require.Equal(t, "Morning standup", got[0].Title)
}

// TestGatherManualItems_FromExistingPlan seeds a plan with 1 manual + 1 focus
// item and verifies gatherManualItems returns only the manual item.
func TestGatherManualItems_FromExistingPlan(t *testing.T) {
	d := gatherTestDB(t)
	p := testPipeline(d)

	today := time.Now().UTC().Format("2006-01-02")
	plan := &db.DayPlan{
		UserID:      "U1",
		PlanDate:    today,
		Status:      "active",
		GeneratedAt: time.Now().UTC(),
	}
	planID, err := d.CreateDayPlan(plan)
	require.NoError(t, err)

	items := []db.DayPlanItem{
		{
			DayPlanID:  planID,
			Kind:       "backlog",
			SourceType: "manual",
			SourceID:   sql.NullString{},
			Title:      "Manual item",
			Priority:   sql.NullString{Valid: true, String: "medium"},
			Status:     "pending",
			Tags:       "[]",
		},
		{
			DayPlanID:  planID,
			Kind:       "timeblock",
			SourceType: "task",
			SourceID:   sql.NullString{Valid: true, String: "42"},
			Title:      "Focus item",
			Priority:   sql.NullString{Valid: true, String: "high"},
			Status:     "pending",
			Tags:       "[]",
		},
	}
	require.NoError(t, d.CreateDayPlanItems(planID, items))

	got, err := p.gatherManualItems(planID)
	require.NoError(t, err)
	require.Len(t, got, 1, "expected only the manual item")
	require.Equal(t, "manual", got[0].SourceType)
	require.Equal(t, "Manual item", got[0].Title)
}

// promptCapturingGenerator records the system and user prompts of the last
// Generate call.
type promptCapturingGenerator struct {
	response string
	prompt   string
}

func (g *promptCapturingGenerator) Generate(_ context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	g.prompt = system + "\n" + user
	return g.response, &digest.Usage{}, "s1", nil
}

// A Jira-only owner (no Slack account) still gets their own assigned issues
// into the day plan — by their Atlassian account id — and never someone
// else's unmapped issue (assignee_slack_id is empty on both).
func TestRun_JiraOnlyOwnerGathersOwnAssignedIssue(t *testing.T) {
	d := gatherTestDB(t)
	_, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", Enabled: true})
	require.NoError(t, err)
	for key, assignee := range map[string]string{"MINE-7": "acc-me", "OTHER-7": "acc-other"} {
		require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
			AccountID: 1, Key: key, ProjectKey: "P", Summary: "Summary " + key,
			Status: "In Progress", StatusCategory: "in_progress", Priority: "High",
			AssigneeAccountID: assignee, Labels: `[]`, Components: `[]`,
			CreatedAt: "2026-04-01T00:00:00Z", UpdatedAt: "2026-04-01T12:00:00Z", SyncedAt: "2026-04-01T12:00:00Z",
		}))
	}
	gen := &promptCapturingGenerator{response: validResponse()}
	p := newTestPipeline(d, gen)

	owner := db.Owner{ID: "jira:acc-me", Source: db.OwnerSourceJira, JiraAccountID: "acc-me"}
	_, err = p.Run(context.Background(), RunOptions{UserID: owner.ID, Owner: owner, Date: "2026-04-23"})
	require.NoError(t, err)

	assert.Contains(t, gen.prompt, "MINE-7")
	assert.NotContains(t, gen.prompt, "OTHER-7")
}

// An owner with neither a Jira account id nor a Slack id gathers no Jira
// issues at all, rather than every unmapped one.
func TestGatherJira_NoJiraOrSlackIdentityGathersNothing(t *testing.T) {
	d := gatherTestDB(t)
	_, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", Enabled: true})
	require.NoError(t, err)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1, Key: "OTHER-8", ProjectKey: "P", Summary: "x",
		Status: "In Progress", StatusCategory: "in_progress",
		Labels: `[]`, Components: `[]`,
		CreatedAt: "2026-04-01T00:00:00Z", UpdatedAt: "2026-04-01T12:00:00Z", SyncedAt: "2026-04-01T12:00:00Z",
	}))
	got := testPipeline(d).gatherJira(db.Owner{ID: "google:me@x.com", Source: db.OwnerSourceGoogle, Email: "me@x.com"})
	assert.Empty(t, got)
}
