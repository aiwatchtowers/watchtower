package inbox

import (
	"context"
	"testing"
	"time"

	"watchtower/internal/db"
)

// ensureCalendar inserts the test calendar row if it doesn't exist yet.
func ensureCalendar(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.Exec(`INSERT OR IGNORE INTO calendar_calendars
		(id, name, is_primary, is_selected, color, synced_at)
		VALUES ('cal-1', 'Test Calendar', 1, 1, '#4285F4', '2026-01-01T00:00:00Z')`)
	if err != nil {
		t.Fatalf("ensureCalendar: %v", err)
	}
}

// seedCalendarEvent inserts a calendar event for testing, starting 1 h from
// now (relative — never hardcode dates in windowed paths). syncedAt is when
// the event was first synced, updatedAt is when it was last updated.
func seedCalendarEvent(t *testing.T, database *db.DB, id, title, attendeesJSON, status string, syncedAt, updatedAt time.Time) {
	t.Helper()
	seedCalendarEventAt(t, database, id, title, attendeesJSON, status,
		syncedAt, updatedAt, time.Now().Add(1*time.Hour), time.Now().Add(2*time.Hour))
}

// seedCalendarEventAt is seedCalendarEvent with explicit start/end times.
func seedCalendarEventAt(t *testing.T, database *db.DB, id, title, attendeesJSON, status string, syncedAt, updatedAt, startTime, endTime time.Time) {
	t.Helper()
	ensureCalendar(t, database)
	syncedStr := syncedAt.UTC().Format(time.RFC3339)
	updatedStr := updatedAt.UTC().Format(time.RFC3339)
	_, err := database.Exec(`
		INSERT INTO calendar_events
			(id, calendar_id, title, attendees, event_status, synced_at, updated_at,
			 start_time, end_time, description, location, organizer_email,
			 is_recurring, is_all_day, event_type, html_link, raw_json)
		VALUES (?, 'cal-1', ?, ?, ?, ?, ?, ?, ?,
		        '', '', '', 0, 0, '', '', '{}')`,
		id, title, attendeesJSON, status, syncedStr, updatedStr,
		startTime.UTC().Format(time.RFC3339), endTime.UTC().Format(time.RFC3339))
	if err != nil {
		t.Fatalf("seedCalendarEventAt: %v", err)
	}
}

func TestCalendarDetector_NewInvite(t *testing.T) {
	d := testDB(t)
	// Event synced 30 min ago, attendee needs to RSVP.
	syncedAt := time.Now().Add(-30 * time.Minute)
	updatedAt := syncedAt
	seedCalendarEvent(t, d, "evt-1", "Team sync",
		`[{"email":"me@x.com","rsvp_status":"needsAction"}]`,
		"confirmed", syncedAt, updatedAt)

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("want 1, got %d", n)
	}
	got := queryInboxByTrigger(t, d, "calendar_invite")
	if len(got) != 1 {
		t.Errorf("want 1 calendar_invite item, got %d", len(got))
	}
}

func TestCalendarDetector_EndedInviteSkipped(t *testing.T) {
	d := testDB(t)
	// History backfill: a 10-day-old event gets a fresh synced_at on first
	// sync with calendar.history_days — it must NOT mint a calendar_invite.
	syncedAt := time.Now().Add(-30 * time.Minute)
	seedCalendarEventAt(t, d, "evt-ended", "Old meeting",
		`[{"email":"me@x.com","rsvp_status":"needsAction"}]`,
		"confirmed", syncedAt, syncedAt,
		time.Now().Add(-10*24*time.Hour), time.Now().Add(-10*24*time.Hour+time.Hour))

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("want 0 for ended invite, got %d", n)
	}
	if got := queryInboxByTrigger(t, d, "calendar_invite"); len(got) != 0 {
		t.Errorf("want 0 calendar_invite items for ended event, got %d", len(got))
	}
}

func TestCalendarDetector_UnparseableEndTimeKeepsInvite(t *testing.T) {
	d := testDB(t)
	// Degenerate: an end_time the RFC3339 parse rejects must keep the invite
	// (conservative — never silently drop a live invite on bad data).
	syncedAt := time.Now().Add(-30 * time.Minute)
	ensureCalendar(t, d)
	_, err := d.Exec(`
		INSERT INTO calendar_events
			(id, calendar_id, title, attendees, event_status, synced_at, updated_at,
			 start_time, end_time)
		VALUES ('evt-badend', 'cal-1', 'Odd event',
		        '[{"email":"me@x.com","rsvp_status":"needsAction"}]',
		        'confirmed', ?, ?, 'not-a-date', 'not-a-date')`,
		syncedAt.UTC().Format(time.RFC3339), syncedAt.UTC().Format(time.RFC3339))
	if err != nil {
		t.Fatal(err)
	}

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("want 1 for unparseable end_time, got %d", n)
	}
}

func TestCalendarDetector_Cancelled(t *testing.T) {
	d := testDB(t)
	// Cancelled event synced 2h ago, updated 1h ago.
	syncedAt := time.Now().Add(-2 * time.Hour)
	updatedAt := time.Now().Add(-1 * time.Hour)
	seedCalendarEvent(t, d, "evt-2", "Cancelled meeting",
		`[{"email":"me@x.com"}]`,
		"cancelled", syncedAt, updatedAt)

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("want 1 cancelled, got %d", n)
	}
	got := queryInboxByTrigger(t, d, "calendar_cancelled")
	if len(got) != 1 {
		t.Errorf("want 1 calendar_cancelled item, got %d", len(got))
	}
}

func TestCalendarDetector_TimeChange(t *testing.T) {
	d := testDB(t)
	// Event synced 2h ago but updated 30min ago (time changed).
	syncedAt := time.Now().Add(-2 * time.Hour)
	updatedAt := time.Now().Add(-30 * time.Minute)
	seedCalendarEvent(t, d, "evt-3", "Rescheduled meeting",
		`[{"email":"me@x.com","rsvp_status":"accepted"}]`,
		"confirmed", syncedAt, updatedAt)

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("want 1 time_change, got %d", n)
	}
	got := queryInboxByTrigger(t, d, "calendar_time_change")
	if len(got) != 1 {
		t.Errorf("want 1 calendar_time_change item, got %d", len(got))
	}
}

func TestCalendarDetector_Deduplication(t *testing.T) {
	d := testDB(t)
	syncedAt := time.Now().Add(-30 * time.Minute)
	updatedAt := syncedAt
	seedCalendarEvent(t, d, "evt-dup", "Sync",
		`[{"email":"me@x.com","rsvp_status":"needsAction"}]`,
		"confirmed", syncedAt, updatedAt)

	since := time.Now().Add(-1 * time.Hour)
	_, _ = DetectCalendar(context.Background(), d, "me@x.com", since)
	n, err := DetectCalendar(context.Background(), d, "me@x.com", since)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("dedupe failed: got %d, want 0", n)
	}
}

func TestCalendarDetector_NotMyEvent(t *testing.T) {
	d := testDB(t)
	syncedAt := time.Now().Add(-30 * time.Minute)
	updatedAt := syncedAt
	// Attendee is someone else, not me.
	seedCalendarEvent(t, d, "evt-other", "Other meeting",
		`[{"email":"other@x.com","rsvp_status":"needsAction"}]`,
		"confirmed", syncedAt, updatedAt)

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("want 0 for non-attendee, got %d", n)
	}
}

func TestCalendarDetector_EmptyEmail(t *testing.T) {
	d := testDB(t)
	n, err := DetectCalendar(context.Background(), d, "", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("want 0 for empty email, got %d", n)
	}
}
