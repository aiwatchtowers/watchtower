package daemon

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/caldav"
	"watchtower/internal/db"
)

// startupCalendarDaemon is an events test daemon with one ICS account whose
// feed serves one upcoming event, and whose calendar already holds a past
// event — so the calendar is not a just-connected backfill.
func startupCalendarDaemon(t *testing.T) (*Daemon, *db.DB, string) {
	t.Helper()
	d, database, _ := newEventsTestDaemon(t, nil)
	start := time.Now().UTC().Add(24 * time.Hour)
	ics := strings.ReplaceAll(fmt.Sprintf(`BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Watchtower Test//EN
BEGIN:VEVENT
UID:startup-uid
DTSTAMP:20260101T000000Z
DTSTART:%s
DTEND:%s
SUMMARY:Planning
END:VEVENT
END:VCALENDAR
`, start.Format("20060102T150405Z"), start.Add(time.Hour).Format("20060102T150405Z")), "\n", "\r\n")
	feed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(ics))
	}))
	t.Cleanup(feed.Close)
	s := icsAccount(t, database, feed.URL)
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: s.CalendarID(), Name: "Feed", IsSelected: true}))
	past := time.Now().UTC().Add(-48 * time.Hour)
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{ID: "earlier", CalendarID: s.CalendarID(), Title: "t",
		StartTime: past.Format(time.RFC3339), EndTime: past.Add(time.Hour).Format(time.RFC3339),
		EventStatus: "confirmed", UpdatedAt: "2026-10-01T00:00:00Z"}))
	d.SetCalDAVSyncers([]*caldav.Syncer{s})
	return d, database, s.CalendarID()
}

// Run's calendar pass ahead of the first cycle is its own event cycle: a
// change it syncs is published and flushed under the pass's own cycle id.
func TestStartupCalendarSync_IsItsOwnEventCycle(t *testing.T) {
	d, _, _ := startupCalendarDaemon(t)
	ev := newRecordingEvents("calendar.event_changed")
	d.SetAutomationEvents(ev)
	before := time.Now()

	d.startupCalendarSync(context.Background())

	calls := ev.callList()
	require.Len(t, calls, 3, "calls: %v", calls)
	assert.Equal(t, []string{"begin", "wants:calendar.event_changed"}, calls[:2])
	cycle, ok := strings.CutPrefix(calls[2], "flush:")
	require.True(t, ok, "the pass ends with its own Flush: %v", calls)
	at, err := time.Parse(time.RFC3339Nano, cycle)
	require.NoError(t, err)
	assert.False(t, at.Before(before), "cycle id %q is the pass's start", cycle)
	require.Len(t, ev.published, 1)
	assert.Equal(t, "created", ev.published[0].Fields["change"])
	assert.Nil(t, d.cycleEvents, "the pass ends its events")
}

// With no bus, or no calendar subscriber, the pass just syncs the calendars.
func TestStartupCalendarSync_NoBusOrNoSubscriberJustSyncs(t *testing.T) {
	d, database, cal := startupCalendarDaemon(t)
	d.startupCalendarSync(context.Background())
	assert.Nil(t, d.cycleEvents)
	events, err := database.GetCalendarEvents(db.CalendarEventFilter{CalendarID: cal})
	require.NoError(t, err)
	assert.NotEmpty(t, events, "the pass synced the feed")

	d, _, _ = startupCalendarDaemon(t)
	ev := newRecordingEvents("slack.new_messages")
	d.SetAutomationEvents(ev)
	d.startupCalendarSync(context.Background())
	calls := ev.callList()
	require.Len(t, calls, 3, "calls: %v", calls)
	assert.Equal(t, "wants:calendar.event_changed", calls[1])
	assert.Empty(t, ev.published)
}
