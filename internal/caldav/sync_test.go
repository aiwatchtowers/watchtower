package caldav

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// testFeed is a mutable ICS feed served over httptest, so tests can change
// the upstream content between syncs (stale-delete) or break it (auth error).
type testFeed struct {
	mu     sync.Mutex
	body   string
	status int
}

func (f *testFeed) set(body string, status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.body, f.status = body, status
}

func (f *testFeed) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	f.mu.Lock()
	body, status := f.body, f.status
	f.mu.Unlock()
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

// feedICS builds an ICS document with events positioned relative to now:
// one timed meeting tomorrow (attendees + organizer), one all-day event
// tomorrow, and one event far outside the sync window.
func feedICS(now time.Time, includeMeeting bool) string {
	tomorrow := now.Add(24 * time.Hour)
	var b strings.Builder
	b.WriteString("BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Watchtower Test//EN\n")
	if includeMeeting {
		b.WriteString(fmt.Sprintf(`BEGIN:VEVENT
UID:meeting-uid
DTSTAMP:20260101T000000Z
DTSTART:%s
DTEND:%s
SUMMARY:Planning
LOCATION:Room 4
ORGANIZER:mailto:boss@example.com
ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com
END:VEVENT
`, tomorrow.Format(instanceTimeFormat), tomorrow.Add(time.Hour).Format(instanceTimeFormat)))
	}
	b.WriteString(fmt.Sprintf(`BEGIN:VEVENT
UID:holiday-uid
DTSTAMP:20260101T000000Z
DTSTART;VALUE=DATE:%s
DTEND;VALUE=DATE:%s
SUMMARY:Holiday
END:VEVENT
BEGIN:VEVENT
UID:far-uid
DTSTAMP:20260101T000000Z
DTSTART:%s
DTEND:%s
SUMMARY:Far future
END:VEVENT
END:VCALENDAR
`, tomorrow.Format("20060102"), tomorrow.Add(24*time.Hour).Format("20060102"),
		now.Add(60*24*time.Hour).Format(instanceTimeFormat), now.Add(60*24*time.Hour+time.Hour).Format(instanceTimeFormat)))
	return crlf(b.String())
}

func newICSSyncer(t *testing.T, database *db.DB, feedURL, label string) (*Syncer, db.CalendarAccount) {
	t.Helper()
	id, err := database.CreateCalendarAccount(db.CalendarAccount{Provider: "ics", Label: label})
	if err != nil {
		t.Fatalf("create calendar account: %v", err)
	}
	acct, err := database.GetCalendarAccount(id)
	if err != nil {
		t.Fatalf("get calendar account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Calendar.SyncDaysAhead = 7
	return NewSyncer(acct, &Credentials{FeedURL: feedURL}, database, cfg, nil), acct
}

func eventIDs(t *testing.T, database *db.DB, calendarID string) []string {
	t.Helper()
	events, err := database.GetCalendarEvents(db.CalendarEventFilter{CalendarID: calendarID})
	if err != nil {
		t.Fatalf("query calendar events: %v", err)
	}
	ids := make([]string, len(events))
	for i, e := range events {
		ids[i] = e.ID
	}
	return ids
}

func TestICSSyncStoresEventsEndToEnd(t *testing.T) {
	feed := &testFeed{}
	feed.set(feedICS(time.Now().UTC(), true), http.StatusOK)
	srv := httptest.NewServer(feed)
	defer srv.Close()
	database := db.OpenTestDB(t)

	syncer, acct := newICSSyncer(t, database, srv.URL, "Personal")
	calID := syncer.CalendarID()
	if want := fmt.Sprintf("ics:%d", acct.ID); calID != want {
		t.Fatalf("CalendarID() = %q, want %q", calID, want)
	}

	n, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if n != 2 {
		t.Fatalf("want 2 events synced (meeting + holiday; far-future outside window), got %d", n)
	}

	events, err := database.GetCalendarEvents(db.CalendarEventFilter{CalendarID: calID})
	if err != nil {
		t.Fatalf("query calendar events: %v", err)
	}
	if len(events) != 2 {
		t.Fatalf("want 2 stored rows, got %d: %v", len(events), eventIDs(t, database, calID))
	}
	byID := map[string]db.CalendarEvent{}
	for _, e := range events {
		byID[e.ID] = e
	}

	meeting, ok := byID[calID+":meeting-uid"]
	if !ok {
		t.Fatalf("meeting row missing (scoped id %s:meeting-uid), have %v", calID, eventIDs(t, database, calID))
	}
	if meeting.Title != "Planning" || meeting.Location != "Room 4" {
		t.Errorf("meeting fields wrong: %+v", meeting)
	}
	if meeting.OrganizerEmail != "boss@example.com" {
		t.Errorf("organizer = %q", meeting.OrganizerEmail)
	}
	if !strings.Contains(meeting.Attendees, `"email":"alice@example.com"`) ||
		!strings.Contains(meeting.Attendees, `"response_status":"accepted"`) {
		t.Errorf("attendees JSON wrong: %s", meeting.Attendees)
	}
	if meeting.IsAllDay || meeting.EventStatus != "confirmed" {
		t.Errorf("meeting flags wrong: %+v", meeting)
	}
	if _, err := time.Parse(time.RFC3339, meeting.StartTime); err != nil {
		t.Errorf("start_time %q is not RFC3339: %v", meeting.StartTime, err)
	}

	holiday, ok := byID[calID+":holiday-uid"]
	if !ok {
		t.Fatalf("holiday row missing, have %v", eventIDs(t, database, calID))
	}
	if !holiday.IsAllDay {
		t.Errorf("holiday must be all-day: %+v", holiday)
	}

	// The account's calendar_calendars row is registered, deselected so the
	// Google syncer's selection query never picks it up.
	cals, err := database.GetCalendars()
	if err != nil {
		t.Fatalf("get calendars: %v", err)
	}
	found := false
	for _, c := range cals {
		if c.ID == calID {
			found = true
			if c.IsSelected {
				t.Errorf("caldav-source calendar must not be is_selected (Google syncer scope)")
			}
			if c.Name != "Personal" {
				t.Errorf("calendar name = %q, want label Personal", c.Name)
			}
		}
	}
	if !found {
		t.Fatalf("calendar_calendars row %s missing", calID)
	}

	updated, err := database.GetCalendarAccount(acct.ID)
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if updated.Status != "ok" {
		t.Errorf("status = %q, want ok", updated.Status)
	}

	// Second sync is idempotent: same rows, same ids, no duplicates.
	n2, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("second Sync: %v", err)
	}
	if n2 != 2 {
		t.Fatalf("want 2 on second sync (window re-fetch), got %d", n2)
	}
	if ids := eventIDs(t, database, calID); len(ids) != 2 {
		t.Fatalf("second sync must not duplicate rows, got %v", ids)
	}
}

func TestICSSyncRemovesEventsDroppedUpstream(t *testing.T) {
	feed := &testFeed{}
	feed.set(feedICS(time.Now().UTC(), true), http.StatusOK)
	srv := httptest.NewServer(feed)
	defer srv.Close()
	database := db.OpenTestDB(t)

	syncer, _ := newICSSyncer(t, database, srv.URL, "")
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if ids := eventIDs(t, database, syncer.CalendarID()); len(ids) != 2 {
		t.Fatalf("precondition: want 2 rows, got %v", ids)
	}

	// The meeting disappears upstream; resync must stale-delete its row.
	// Advance the syncer's clock so the second sync's syncedAt stamp is
	// strictly newer at RFC3339 second resolution.
	syncer.now = func() time.Time { return time.Now().Add(2 * time.Second) }
	feed.set(feedICS(time.Now().UTC(), false), http.StatusOK)
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("resync: %v", err)
	}
	ids := eventIDs(t, database, syncer.CalendarID())
	if len(ids) != 1 || !strings.HasSuffix(ids[0], ":holiday-uid") {
		t.Fatalf("want only the holiday row after upstream removal, got %v", ids)
	}
}

func TestICSSyncBrokenFeedSetsErrorStatusThenRecovers(t *testing.T) {
	feed := &testFeed{}
	feed.set("boom", http.StatusInternalServerError)
	srv := httptest.NewServer(feed)
	defer srv.Close()
	database := db.OpenTestDB(t)

	syncer, acct := newICSSyncer(t, database, srv.URL, "")
	if _, err := syncer.Sync(context.Background()); err == nil {
		t.Fatal("want error for broken feed, got nil")
	}
	updated, err := database.GetCalendarAccount(acct.ID)
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if updated.Status != "error" || updated.Error == "" {
		t.Errorf("want status=error with a message, got status=%q error=%q", updated.Status, updated.Error)
	}

	// Feed comes back: next sync succeeds and clears the error state.
	feed.set(feedICS(time.Now().UTC(), true), http.StatusOK)
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("recovered Sync: %v", err)
	}
	updated, err = database.GetCalendarAccount(acct.ID)
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if updated.Status != "ok" || updated.Error != "" {
		t.Errorf("want status=ok after recovery, got status=%q error=%q", updated.Status, updated.Error)
	}
}

// TestICSSyncSameUIDAcrossAccountsStaysDistinct covers the account-scoped id
// contract: iCalendar UIDs are not unique across accounts (same lesson as
// IMAP's channel/account scoping), so the same UID synced by two accounts
// must land as two distinct rows under two distinct calendar_ids.
func TestICSSyncSameUIDAcrossAccountsStaysDistinct(t *testing.T) {
	feed := &testFeed{}
	feed.set(feedICS(time.Now().UTC(), true), http.StatusOK)
	srv := httptest.NewServer(feed)
	defer srv.Close()
	database := db.OpenTestDB(t)

	syncerA, acctA := newICSSyncer(t, database, srv.URL, "A")
	syncerB, acctB := newICSSyncer(t, database, srv.URL, "B")

	if _, err := syncerA.Sync(context.Background()); err != nil {
		t.Fatalf("Sync A: %v", err)
	}
	if _, err := syncerB.Sync(context.Background()); err != nil {
		t.Fatalf("Sync B: %v", err)
	}

	idsA := eventIDs(t, database, fmt.Sprintf("ics:%d", acctA.ID))
	idsB := eventIDs(t, database, fmt.Sprintf("ics:%d", acctB.ID))
	if len(idsA) != 2 || len(idsB) != 2 {
		t.Fatalf("want 2 rows per account, got A=%v B=%v", idsA, idsB)
	}
	for _, id := range idsA {
		for _, other := range idsB {
			if id == other {
				t.Errorf("event id %q collides across accounts", id)
			}
		}
	}
}

// TestICSSyncHistoryWindowWidening pins spec §6's "applies to Google and
// CalDAV syncers alike": history_days drives the CalDAV/ICS window start the
// same way it drives the Google syncer's timeMin. A first sync with a wide
// window stores two past events; narrowing history_days to 14 keeps the
// 10-day-old event and stale-deletes the 20-day-old one (all times relative
// to now — no hardcoded dates in windowed paths).
func TestICSSyncHistoryWindowWidening(t *testing.T) {
	now := time.Now().UTC()
	old10 := now.Add(-10 * 24 * time.Hour)
	old20 := now.Add(-20 * 24 * time.Hour)

	body := crlf(fmt.Sprintf(`BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Watchtower Test//EN
BEGIN:VEVENT
UID:evt-10d
DTSTAMP:20260101T000000Z
DTSTART:%s
DTEND:%s
SUMMARY:Ten days ago
END:VEVENT
BEGIN:VEVENT
UID:evt-20d
DTSTAMP:20260101T000000Z
DTSTART:%s
DTEND:%s
SUMMARY:Twenty days ago
END:VEVENT
END:VCALENDAR
`, old10.Format(instanceTimeFormat), old10.Add(time.Hour).Format(instanceTimeFormat),
		old20.Format(instanceTimeFormat), old20.Add(time.Hour).Format(instanceTimeFormat)))

	feed := &testFeed{}
	feed.set(body, http.StatusOK)
	srv := httptest.NewServer(feed)
	defer srv.Close()
	database := db.OpenTestDB(t)

	syncer, _ := newICSSyncer(t, database, srv.URL, "History")
	syncer.appConfig.Calendar.HistoryDays = 25
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("wide sync: %v", err)
	}
	if ids := eventIDs(t, database, syncer.CalendarID()); len(ids) != 2 {
		t.Fatalf("precondition: want both past events with history_days=25, got %v", ids)
	}

	// Narrow the window: the 20-day-old event leaves it, is not re-stamped,
	// and gets stale-deleted. Advance the clock so syncedAt is strictly newer
	// at RFC3339 second resolution.
	syncer.appConfig.Calendar.HistoryDays = 14
	syncer.now = func() time.Time { return time.Now().Add(2 * time.Second) }
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("narrow sync: %v", err)
	}
	ids := eventIDs(t, database, syncer.CalendarID())
	if len(ids) != 1 || !strings.HasSuffix(ids[0], ":evt-10d") {
		t.Fatalf("want only the 10-day-old event with history_days=14, got %v", ids)
	}
}
