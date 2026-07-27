package caldav

import (
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/emersion/go-ical"
)

// crlf converts \n-separated test fixtures to the CRLF line endings the
// iCalendar wire format requires.
func crlf(s string) string {
	return strings.ReplaceAll(s, "\n", "\r\n")
}

func parseICS(t *testing.T, ics string) []ical.Event {
	t.Helper()
	cal, err := ical.NewDecoder(strings.NewReader(crlf(ics))).Decode()
	if err != nil {
		t.Fatalf("parsing test ICS: %v", err)
	}
	return cal.Events()
}

func discardLogger() *log.Logger {
	return log.New(io.Discard, "", 0)
}

const fixtureBasicICS = `BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Watchtower Test//EN
BEGIN:VEVENT
UID:meeting-1
DTSTAMP:20260101T000000Z
DTSTART:20260112T090000Z
DTEND:20260112T100000Z
SUMMARY:Team standup
LOCATION:Zoom
DESCRIPTION:Daily sync
ORGANIZER:mailto:boss@example.com
ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com
ATTENDEE;CN=Bob;PARTSTAT=NEEDS-ACTION:mailto:bob@example.com
END:VEVENT
BEGIN:VEVENT
UID:far-future
DTSTAMP:20260101T000000Z
DTSTART:20260301T090000Z
DTEND:20260301T100000Z
SUMMARY:Far future
END:VEVENT
BEGIN:VEVENT
UID:holiday-1
DTSTAMP:20260101T000000Z
DTSTART;VALUE=DATE:20260113
DTEND;VALUE=DATE:20260114
SUMMARY:Company holiday
END:VEVENT
BEGIN:VEVENT
UID:cancelled-1
DTSTAMP:20260101T000000Z
DTSTART:20260112T150000Z
DTEND:20260112T160000Z
STATUS:CANCELLED
SUMMARY:Cancelled meeting
END:VEVENT
END:VCALENDAR
`

func TestExpandEventsWindowFilteringAndFields(t *testing.T) {
	events := parseICS(t, fixtureBasicICS)
	winStart := time.Date(2026, 1, 10, 0, 0, 0, 0, time.UTC)
	winEnd := time.Date(2026, 1, 17, 0, 0, 0, 0, time.UTC)

	out := expandEvents(events, winStart, winEnd, discardLogger())
	if len(out) != 2 {
		t.Fatalf("want 2 window-relevant events (meeting + holiday; far-future out of window, cancelled skipped), got %d: %+v", len(out), out)
	}

	byUID := map[string]Event{}
	for _, e := range out {
		byUID[e.UID] = e
	}

	m, ok := byUID["meeting-1"]
	if !ok {
		t.Fatalf("meeting-1 missing from %v", byUID)
	}
	if m.Title != "Team standup" || m.Location != "Zoom" || m.Description != "Daily sync" {
		t.Errorf("meeting fields wrong: %+v", m)
	}
	if got := m.Start.Format(time.RFC3339); got != "2026-01-12T09:00:00Z" {
		t.Errorf("meeting start = %s, want 2026-01-12T09:00:00Z", got)
	}
	if got := m.End.Format(time.RFC3339); got != "2026-01-12T10:00:00Z" {
		t.Errorf("meeting end = %s, want 2026-01-12T10:00:00Z", got)
	}
	if m.Organizer != "boss@example.com" {
		t.Errorf("organizer = %q, want boss@example.com", m.Organizer)
	}
	if m.IsAllDay || m.Recurring || m.Status != "confirmed" {
		t.Errorf("meeting flags wrong: %+v", m)
	}
	if len(m.Attendees) != 2 {
		t.Fatalf("want 2 attendees, got %+v", m.Attendees)
	}
	if a := m.Attendees[0]; a.Email != "alice@example.com" || a.DisplayName != "Alice" || a.ResponseStatus != "accepted" {
		t.Errorf("attendee 0 wrong: %+v", a)
	}
	if a := m.Attendees[1]; a.Email != "bob@example.com" || a.ResponseStatus != "needsAction" {
		t.Errorf("attendee 1 wrong: %+v", a)
	}

	h, ok := byUID["holiday-1"]
	if !ok {
		t.Fatalf("holiday-1 missing from %v", byUID)
	}
	if !h.IsAllDay {
		t.Errorf("holiday must be all-day: %+v", h)
	}
	if got := h.Start.Format(time.RFC3339); got != "2026-01-13T00:00:00Z" {
		t.Errorf("holiday start = %s, want 2026-01-13T00:00:00Z", got)
	}
}

const fixtureRecurringICS = `BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Watchtower Test//EN
BEGIN:VEVENT
UID:standup
DTSTAMP:20260101T000000Z
DTSTART:20260101T090000Z
DTEND:20260101T093000Z
RRULE:FREQ=DAILY
EXDATE:20260112T090000Z
SUMMARY:Standup
END:VEVENT
BEGIN:VEVENT
UID:standup
DTSTAMP:20260101T000000Z
RECURRENCE-ID:20260113T090000Z
DTSTART:20260113T140000Z
DTEND:20260113T143000Z
SUMMARY:Standup (moved)
END:VEVENT
BEGIN:VEVENT
UID:standup
DTSTAMP:20260101T000000Z
RECURRENCE-ID:20260115T090000Z
DTSTART:20260115T090000Z
DTEND:20260115T093000Z
STATUS:CANCELLED
SUMMARY:Standup
END:VEVENT
END:VCALENDAR
`

// TestExpandEventsRecurringDaily covers the recurrence contract: a daily
// RRULE is expanded into in-window occurrences with the occurrence start
// appended to the instance UID, EXDATE removes an occurrence, a
// RECURRENCE-ID override replaces its base occurrence (moved standup), and a
// cancelled override drops the occurrence entirely.
func TestExpandEventsRecurringDaily(t *testing.T) {
	events := parseICS(t, fixtureRecurringICS)
	winStart := time.Date(2026, 1, 10, 0, 0, 0, 0, time.UTC)
	winEnd := time.Date(2026, 1, 17, 0, 0, 0, 0, time.UTC)

	out := expandEvents(events, winStart, winEnd, discardLogger())

	// Jan 10..16 daily = 7 occurrences, minus EXDATE (12th), minus overridden
	// (13th, replaced by the moved override), minus cancelled override (15th)
	// = 4 base instances + 1 override instance = 5.
	if len(out) != 5 {
		t.Fatalf("want 5 expanded instances, got %d: %+v", len(out), out)
	}

	byUID := map[string]Event{}
	for _, e := range out {
		if !e.Recurring {
			t.Errorf("instance %s must be marked recurring", e.UID)
		}
		byUID[e.UID] = e
	}

	for _, want := range []string{
		"standup:20260110T090000Z",
		"standup:20260111T090000Z",
		"standup:20260114T090000Z",
		"standup:20260116T090000Z",
	} {
		if _, ok := byUID[want]; !ok {
			t.Errorf("missing base instance %s (have %v)", want, uids(out))
		}
	}
	if _, ok := byUID["standup:20260112T090000Z"]; ok {
		t.Errorf("EXDATE occurrence must be excluded")
	}
	if _, ok := byUID["standup:20260115T090000Z"]; ok {
		t.Errorf("cancelled override occurrence must be excluded")
	}

	// The moved override keeps the ORIGINAL occurrence start in its instance
	// UID (so it replaces the base occurrence's row) but carries new times.
	moved, ok := byUID["standup:20260113T090000Z"]
	if !ok {
		t.Fatalf("missing override instance standup:20260113T090000Z (have %v)", uids(out))
	}
	if moved.Title != "Standup (moved)" {
		t.Errorf("override title = %q, want Standup (moved)", moved.Title)
	}
	if got := moved.Start.Format(time.RFC3339); got != "2026-01-13T14:00:00Z" {
		t.Errorf("override start = %s, want 2026-01-13T14:00:00Z", got)
	}
}

func uids(events []Event) []string {
	out := make([]string, len(events))
	for i, e := range events {
		out[i] = e.UID
	}
	return out
}

// TestExpandEventsLongEventOverlappingWindowStart covers the widened
// Between() lower bound: an occurrence starting before the window whose
// duration reaches into it must still be included.
func TestExpandEventsLongEventOverlappingWindowStart(t *testing.T) {
	events := parseICS(t, `BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Watchtower Test//EN
BEGIN:VEVENT
UID:overnight
DTSTAMP:20260101T000000Z
DTSTART:20260109T220000Z
DTEND:20260110T020000Z
SUMMARY:Overnight deploy
END:VEVENT
END:VCALENDAR
`)
	winStart := time.Date(2026, 1, 10, 0, 0, 0, 0, time.UTC)
	winEnd := time.Date(2026, 1, 17, 0, 0, 0, 0, time.UTC)

	out := expandEvents(events, winStart, winEnd, discardLogger())
	if len(out) != 1 || out[0].UID != "overnight" {
		t.Fatalf("want the overlapping overnight event included, got %+v", out)
	}
}

func TestToDBEventScopesIDAndMirrorsGoogleRowShape(t *testing.T) {
	ev := Event{
		UID:       "abc",
		Title:     "T",
		Start:     time.Date(2026, 1, 12, 9, 0, 0, 0, time.UTC),
		End:       time.Date(2026, 1, 12, 10, 0, 0, 0, time.UTC),
		Status:    "confirmed",
		Recurring: true,
	}
	row := toDBEvent(ev, "caldav:7", `[]`)
	if row.ID != "caldav:7:abc" {
		t.Errorf("row id = %q, want caldav:7:abc (account-scoped)", row.ID)
	}
	if row.CalendarID != "caldav:7" {
		t.Errorf("calendar_id = %q, want caldav:7", row.CalendarID)
	}
	if row.StartTime != "2026-01-12T09:00:00Z" || row.EndTime != "2026-01-12T10:00:00Z" {
		t.Errorf("times not RFC3339 UTC: %q / %q", row.StartTime, row.EndTime)
	}
	if !row.IsRecurring || row.RawJSON != "{}" || row.Attendees != "[]" || row.EventType != "default" {
		t.Errorf("row shape wrong: %+v", row)
	}
}
