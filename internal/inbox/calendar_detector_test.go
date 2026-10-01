package inbox

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"watchtower/internal/calendar"
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
		`[{"email":"me@x.com","response_status":"needsAction"}]`,
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
		`[{"email":"me@x.com","response_status":"needsAction"}]`,
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
		        '[{"email":"me@x.com","response_status":"needsAction"}]',
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

// syncCalendarEvent writes an event through the production upsert, exactly
// as the Google/CalDAV syncers do on each sync pass: synced_at is the pass's
// own time and updated_at the provider's last-modified stamp, which always
// precedes the pass that fetched it.
func syncCalendarEvent(t *testing.T, database *db.DB, id, attendeesJSON string, start, end, updated, syncedAt time.Time) {
	t.Helper()
	ensureCalendar(t, database)
	ev := db.CalendarEvent{
		ID: id, CalendarID: "cal-1", Title: "Rescheduled meeting",
		StartTime: start.UTC().Format(time.RFC3339), EndTime: end.UTC().Format(time.RFC3339),
		Attendees: attendeesJSON, EventStatus: "confirmed", RawJSON: "{}",
		UpdatedAt: updated.UTC().Format(time.RFC3339),
	}
	if err := database.UpsertCalendarEvent(ev, syncedAt.UTC().Format(time.RFC3339)); err != nil {
		t.Fatalf("syncCalendarEvent: %v", err)
	}
}

func TestCalendarDetector_TimeChange(t *testing.T) {
	d := testDB(t)
	attendees := `[{"email":"me@x.com","response_status":"accepted"}]`
	start := time.Now().Add(3 * time.Hour)
	// First sync 2h ago; the organizer then moves the meeting 30 min ago and
	// the next sync (just now) picks the new time up. synced_at is rewritten
	// on every pass, so it is always newer than the provider's updated_at.
	syncCalendarEvent(t, d, "evt-3", attendees, start, start.Add(time.Hour),
		time.Now().Add(-3*time.Hour), time.Now().Add(-2*time.Hour))
	moved := start.Add(24 * time.Hour)
	syncCalendarEvent(t, d, "evt-3", attendees, moved, moved.Add(time.Hour),
		time.Now().Add(-30*time.Minute), time.Now())

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
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

	// A later edit that leaves the time alone (a new description, say) bumps
	// updated_at again but is not another reschedule.
	syncCalendarEvent(t, d, "evt-3", attendees, moved, moved.Add(time.Hour),
		time.Now().Add(-5*time.Minute), time.Now().Add(time.Second))
	if _, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if got := queryInboxByTrigger(t, d, "calendar_time_change"); len(got) != 1 {
		t.Errorf("a non-time edit after a reschedule: want still 1 calendar_time_change item, got %d", len(got))
	}
}

// TestCalendarDetector_ResyncWithoutTimeChange is the degenerate branch: an
// event re-synced with a newer updated_at but the same start/end (a detail
// edit) is not a reschedule and mints nothing.
func TestCalendarDetector_ResyncWithoutTimeChange(t *testing.T) {
	d := testDB(t)
	attendees := `[{"email":"me@x.com","response_status":"accepted"}]`
	start := time.Now().Add(3 * time.Hour)
	syncCalendarEvent(t, d, "evt-4", attendees, start, start.Add(time.Hour),
		time.Now().Add(-3*time.Hour), time.Now().Add(-2*time.Hour))
	syncCalendarEvent(t, d, "evt-4", attendees, start, start.Add(time.Hour),
		time.Now().Add(-30*time.Minute), time.Now())

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("want 0 for a re-sync without a time change, got %d", n)
	}
}

// TestCalendarDetector_TimeChangeBeforeWindowIgnored: a reschedule the
// detector already had its chance at (before sinceTS) does not fire again.
func TestCalendarDetector_TimeChangeBeforeWindowIgnored(t *testing.T) {
	d := testDB(t)
	attendees := `[{"email":"me@x.com","response_status":"accepted"}]`
	start := time.Now().Add(3 * time.Hour)
	syncCalendarEvent(t, d, "evt-5", attendees, start, start.Add(time.Hour),
		time.Now().Add(-5*time.Hour), time.Now().Add(-4*time.Hour))
	moved := start.Add(time.Hour)
	syncCalendarEvent(t, d, "evt-5", attendees, moved, moved.Add(time.Hour),
		time.Now().Add(-3*time.Hour), time.Now().Add(-2*time.Hour))

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("want 0 for a reschedule before the window, got %d", n)
	}
}

func TestCalendarDetector_Deduplication(t *testing.T) {
	d := testDB(t)
	syncedAt := time.Now().Add(-30 * time.Minute)
	updatedAt := syncedAt
	seedCalendarEvent(t, d, "evt-dup", "Sync",
		`[{"email":"me@x.com","response_status":"needsAction"}]`,
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
		`[{"email":"other@x.com","response_status":"needsAction"}]`,
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

// productionAttendees renders the attendees column exactly as the Google and
// CalDAV syncers write it (calendar.Attendee), so the detector is pinned to
// the real wire shape rather than a hand-written fixture key.
func productionAttendees(t *testing.T, email, status string) string {
	t.Helper()
	b, err := json.Marshal([]calendar.Attendee{{Email: email, ResponseStatus: status}})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestCalendarDetector_ProductionAttendeeShape(t *testing.T) {
	d := testDB(t)
	syncedAt := time.Now().Add(-30 * time.Minute)
	seedCalendarEvent(t, d, "evt-prod", "Team sync",
		productionAttendees(t, "me@x.com", "needsAction"),
		"confirmed", syncedAt, syncedAt)

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 calendar_invite from a syncer-shaped attendees column, got %d", n)
	}
}

func TestCalendarDetector_OwnerEmailCaseInsensitive(t *testing.T) {
	d := testDB(t)
	syncedAt := time.Now().Add(-30 * time.Minute)
	seedCalendarEvent(t, d, "evt-case", "Team sync",
		productionAttendees(t, "Me@X.com", "needsAction"),
		"confirmed", syncedAt, syncedAt)

	n, err := DetectCalendar(context.Background(), d, "me@x.com", time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("attendee email differing only in case must still match the owner, got %d items", n)
	}
}

func TestCalendarResolveReason(t *testing.T) {
	now := time.Now()
	moveTS := now.Add(-time.Hour).UTC().Format(time.RFC3339)
	before := now.Add(-2 * time.Hour).UTC().Format(time.RFC3339)
	after := now.Add(-30 * time.Minute).UTC().Format(time.RFC3339)
	future := now.Add(2 * time.Hour).UTC().Format(time.RFC3339)
	past := now.Add(-10 * time.Minute).UTC().Format(time.RFC3339)
	tc := calendarResolveCandidate{trigger: "calendar_time_change", itemTS: moveTS}
	inv := calendarResolveCandidate{trigger: "calendar_invite", itemTS: before}
	cases := []struct {
		name                string
		c                   calendarResolveCandidate
		rsvp, changed, endT string
		want                string
	}{
		{"invite answered", inv, "accepted", "", future, "User responded to invite"},
		{"invite unanswered", inv, "needsAction", "", past, ""},
		{"time change, RSVP kept from before", tc, "accepted", before, future, ""},
		{"time change, RSVP never changed", tc, "accepted", "", future, ""},
		{"time change, answered after", tc, "declined", after, future, "User responded after the reschedule"},
		{"time change, answered on the move's pass", tc, "accepted", moveTS, future, "User responded after the reschedule"},
		{"time change, reset after but unanswered", tc, "needsAction", after, future, ""},
		{"time change, ended", tc, "accepted", before, past, "Event has ended"},
		{"time change, unparseable end", tc, "accepted", before, "not-a-date", ""},
	}
	for _, c := range cases {
		if got := calendarResolveReason(c.c, c.rsvp, c.changed, c.endT, now); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
