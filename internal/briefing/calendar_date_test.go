package briefing

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// The briefing's calendar section reads the day the briefing is FOR (a
// RunForDate for another day must not show today's meetings), and yesterday's
// all-day event does not leak into it.
func TestGatherCalendar_ReadsTheBriefingDate(t *testing.T) {
	p := newTestPipeline(t)
	require.NoError(t, p.db.UpsertCalendar(0, db.CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: time.Now().UTC().Format(time.RFC3339)}))

	now := time.Now()
	tomorrow := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local).AddDate(0, 0, 1)
	date := tomorrow.Format("2006-01-02")
	allDay := func(d time.Time) string { return d.Format("2006-01-02") + "T00:00:00Z" }
	for _, ev := range []db.CalendarEvent{
		{ID: "tomorrow-sync", Title: "Tomorrow sync", StartTime: tomorrow.Add(10 * time.Hour).UTC().Format(time.RFC3339), EndTime: tomorrow.Add(11 * time.Hour).UTC().Format(time.RFC3339)},
		{ID: "today-offsite", Title: "Today offsite", StartTime: allDay(tomorrow.AddDate(0, 0, -1)), EndTime: allDay(tomorrow), IsAllDay: true},
	} {
		ev.CalendarID = "primary"
		require.NoError(t, p.db.UpsertCalendarEvent(ev))
	}

	got := p.gatherCalendar(date)
	assert.Contains(t, got, "Tomorrow sync")
	assert.NotContains(t, got, "Today offsite", "the previous day's all-day event ends at this day's midnight")
	assert.Empty(t, p.gatherCalendar(tomorrow.AddDate(0, 0, 5).Format("2006-01-02")))
}
