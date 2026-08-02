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
	if err := d.UpsertCalendar(0, db.CalendarCalendar{ID: "cal1", Name: "Main", SyncedAt: "2026-07-01T00:00:00Z"}); err != nil {
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

func TestBuildSecretaryBrief_OwnerEmailAddresses(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")

	if _, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A", GmailEnabled: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "b@y.com", Label: "B", GmailEnabled: true}); err != nil {
		t.Fatal(err)
	}

	got := buildSecretaryBrief(d, "U1", time.Now())
	if !strings.Contains(got, "Owner email addresses: a@x.com, b@y.com") {
		t.Errorf("brief missing owner email addresses line, got:\n%s", got)
	}
}

func TestBuildSecretaryBrief_NoAccountsOmitsOwnerEmailsSection(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")

	got := buildSecretaryBrief(d, "U1", time.Now())
	if strings.Contains(got, "Owner email addresses") {
		t.Errorf("brief must omit the owner-emails line when no account is connected, got:\n%s", got)
	}
}

// The tracks section names people, not Slack IDs: ball_on holds a raw user id
// (db.Track.BallOn) and track text can carry <@U...> mentions — both must be
// resolved before reaching the AI prompt, or the composer copies raw IDs into
// situation titles (seen in the field: "U010T5CNTJT повторно уклонился").
func TestBuildSecretaryBrief_TracksResolveUserIDs(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	if _, err := d.Exec(`INSERT INTO users (id, name, display_name) VALUES ('U010TESTID', 'serhii', 'Serhii Lizunov')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.UpsertTrack(db.Track{
		Text:     "KYC tiers: waiting on <@U010TESTID> to clarify",
		Priority: "high",
		BallOn:   "U010TESTID",
	}); err != nil {
		t.Fatal(err)
	}

	got := buildSecretaryBrief(d, "U1", time.Date(2026, 7, 5, 10, 0, 0, 0, time.UTC))
	if !strings.Contains(got, "ball on: Serhii Lizunov") {
		t.Errorf("brief should resolve ball_on to a display name\n---\n%s", got)
	}
	if strings.Contains(got, "U010TESTID") {
		t.Errorf("brief must not leak raw user IDs\n---\n%s", got)
	}
}
