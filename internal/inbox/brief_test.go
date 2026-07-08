package inbox

import (
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
)

func TestBuildSecretaryBrief_AllSections(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	if err := d.SetSecretaryProfile("I run direction X. CEO pings are always action."); err != nil {
		t.Fatal(err)
	}

	// One active track.
	if _, err := d.UpsertTrack(db.Track{Text: "Ship the API redesign", Priority: "high", BallOn: "U1"}); err != nil {
		t.Fatal(err)
	}

	// One open Jira issue assigned to U1.
	if err := d.UpsertJiraIssue(db.JiraIssue{
		Key: "P-1", ProjectKey: "P", Summary: "Fix login bug", Status: "Open",
		StatusCategory: "todo", AssigneeSlackID: "U1",
		CreatedAt: "2026-07-01T00:00:00Z", UpdatedAt: "2026-07-01T00:00:00Z", SyncedAt: "2026-07-01T00:00:00Z",
	}); err != nil {
		t.Fatal(err)
	}

	// One calendar event for today (2026-07-05).
	if err := d.UpsertCalendar(db.CalendarCalendar{ID: "cal1", Name: "Main", SyncedAt: "2026-07-01T00:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	if err := d.UpsertCalendarEvent(db.CalendarEvent{
		ID: "e1", CalendarID: "cal1", Title: "Standup",
		StartTime: "2026-07-05T09:00:00Z", EndTime: "2026-07-05T09:30:00Z",
	}); err != nil {
		t.Fatal(err)
	}

	got := buildSecretaryBrief(d, "U1", time.Date(2026, 7, 5, 10, 0, 0, 0, time.UTC))
	for _, want := range []string{
		"=== SECRETARY BRIEF ===",
		"I run direction X. CEO pings are always action.",
		"ACTIVE TRACKS", "MY OPEN JIRA", "TODAY'S CALENDAR",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("brief missing %q\n---\n%s", want, got)
		}
	}
}

func TestBuildSecretaryBrief_EmptySourcesStillUsable(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	got := buildSecretaryBrief(d, "U1", time.Now())
	if !strings.Contains(got, "=== SECRETARY BRIEF ===") {
		t.Fatalf("brief must always carry its header, got: %q", got)
	}
	if strings.Contains(got, "ACTIVE TRACKS") {
		t.Errorf("empty track list must omit the section")
	}
}
