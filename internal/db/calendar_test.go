package db

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestUpsertAndGetCalendars(t *testing.T) {
	db := openTestDB(t)

	err := db.UpsertCalendar(0, CalendarCalendar{
		ID: "primary", Name: "Main", IsPrimary: true, IsSelected: true, Color: "#4285f4", SyncedAt: "2026-04-01T00:00:00Z",
	})
	require.NoError(t, err)

	err = db.UpsertCalendar(0, CalendarCalendar{
		ID: "work@example.com", Name: "Work", IsPrimary: false, IsSelected: true, Color: "#0b8043", SyncedAt: "2026-04-01T00:00:00Z",
	})
	require.NoError(t, err)

	cals, err := db.GetCalendars()
	require.NoError(t, err)
	assert.Len(t, cals, 2)
	// Primary first (ORDER BY is_primary DESC).
	assert.Equal(t, "primary", cals[0].ID)
	assert.True(t, cals[0].IsPrimary)
	assert.Equal(t, "work@example.com", cals[1].ID)
}

func TestUpsertCalendar_UpdatesOnConflict(t *testing.T) {
	db := openTestDB(t)

	err := db.UpsertCalendar(0, CalendarCalendar{ID: "cal1", Name: "Old Name", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"})
	require.NoError(t, err)

	err = db.UpsertCalendar(0, CalendarCalendar{ID: "cal1", Name: "New Name", IsSelected: true, SyncedAt: "2026-04-02T00:00:00Z"})
	require.NoError(t, err)

	cals, err := db.GetCalendars()
	require.NoError(t, err)
	assert.Len(t, cals, 1)
	assert.Equal(t, "New Name", cals[0].Name)
	assert.Equal(t, "2026-04-02T00:00:00Z", cals[0].SyncedAt)
}

// TestUpsertCalendar_KeepsOriginalOwner guards the shared-calendar-keyspace
// fix: calendar_calendars.id is shared across google_accounts (a public or
// subscribed calendar synced by two different accounts hits the SAME row).
// Ownership must never transfer on conflict — otherwise the later-syncing
// account's stale-delete pass would end up deleting the first owner's
// freshly-synced events for that calendar.
func TestUpsertCalendar_KeepsOriginalOwner(t *testing.T) {
	db := openTestDB(t)

	acctA, err := db.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	acctB, err := db.CreateGoogleAccount(GoogleAccount{Email: "b@x.com", Label: "B"})
	require.NoError(t, err)

	require.NoError(t, db.UpsertCalendar(acctA, CalendarCalendar{ID: "shared", Name: "Shared (A's view)", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))
	// Account B syncs the same shared calendar id next — must not steal ownership.
	require.NoError(t, db.UpsertCalendar(acctB, CalendarCalendar{ID: "shared", Name: "Shared (B's view)", IsSelected: true, SyncedAt: "2026-04-02T00:00:00Z"}))

	idsA, err := db.GetSelectedCalendarIDs(acctA)
	require.NoError(t, err)
	assert.Equal(t, []string{"shared"}, idsA, "account A must keep ownership of the shared calendar")

	idsB, err := db.GetSelectedCalendarIDs(acctB)
	require.NoError(t, err)
	assert.Empty(t, idsB, "account B must never see the shared calendar as its own")

	// Name/color/synced_at still update from whichever account synced last —
	// only account_id ownership is frozen.
	cals, err := db.GetCalendars()
	require.NoError(t, err)
	require.Len(t, cals, 1)
	assert.Equal(t, "Shared (B's view)", cals[0].Name)
}

// TestUpsertCalendar_ClaimsUnownedRow guards the other half of the fix: a
// NULL-account row (never synced by any google_accounts row, or a legacy row
// pre-dating multi-account) can still be claimed by the first account that
// syncs it — ownership only freezes once a non-NULL owner exists.
func TestUpsertCalendar_ClaimsUnownedRow(t *testing.T) {
	db := openTestDB(t)

	acctA, err := db.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	// Legacy/unowned row (account_id NULL), as migration 00043 would leave a
	// pre-multi-account calendar until claimed.
	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "legacy", Name: "Legacy", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))

	require.NoError(t, db.UpsertCalendar(acctA, CalendarCalendar{ID: "legacy", Name: "Legacy", IsSelected: true, SyncedAt: "2026-04-02T00:00:00Z"}))

	ids, err := db.GetSelectedCalendarIDs(acctA)
	require.NoError(t, err)
	assert.Equal(t, []string{"legacy"}, ids)
}

func TestGetSelectedCalendarIDs(t *testing.T) {
	db := openTestDB(t)

	acctID, err := db.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	require.NoError(t, db.UpsertCalendar(acctID, CalendarCalendar{ID: "cal1", Name: "C1", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, db.UpsertCalendar(acctID, CalendarCalendar{ID: "cal2", Name: "C2", IsSelected: false, SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, db.UpsertCalendar(acctID, CalendarCalendar{ID: "cal3", Name: "C3", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))
	// A NULL-account (caldav/ics) selected calendar must never show up.
	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "caldav:1", Name: "CalDAV", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))

	ids, err := db.GetSelectedCalendarIDs(acctID)
	require.NoError(t, err)
	assert.Len(t, ids, 2)
	assert.Contains(t, ids, "cal1")
	assert.Contains(t, ids, "cal3")
}

func TestSetCalendarSelected(t *testing.T) {
	db := openTestDB(t)

	acctID, err := db.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	require.NoError(t, db.UpsertCalendar(acctID, CalendarCalendar{ID: "cal1", Name: "C1", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))

	err = db.SetCalendarSelected("cal1", false)
	require.NoError(t, err)

	ids, err := db.GetSelectedCalendarIDs(acctID)
	require.NoError(t, err)
	assert.Empty(t, ids)

	err = db.SetCalendarSelected("cal1", true)
	require.NoError(t, err)

	ids, err = db.GetSelectedCalendarIDs(acctID)
	require.NoError(t, err)
	assert.Len(t, ids, 1)
}

func TestUpsertAndGetCalendarEvents(t *testing.T) {
	db := openTestDB(t)

	// Need a calendar first (foreign key).
	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: "2026-04-01T00:00:00Z"}))

	ev := CalendarEvent{
		ID:             "evt1",
		CalendarID:     "primary",
		Title:          "Team Standup",
		Description:    "Daily standup",
		Location:       "Room 42",
		StartTime:      "2026-04-02T09:00:00Z",
		EndTime:        "2026-04-02T09:30:00Z",
		OrganizerEmail: "alice@example.com",
		Attendees:      `[{"email":"bob@example.com"}]`,
		IsRecurring:    true,
		IsAllDay:       false,
		EventStatus:    "confirmed",
		EventType:      "default",
		HTMLLink:       "https://calendar.google.com/event?id=evt1",
		RawJSON:        `{"id":"evt1"}`,
		ICalUID:        "evt1@google.com",
		UpdatedAt:      "2026-04-01T12:00:00Z",
	}

	err := db.UpsertCalendarEvent(ev)
	require.NoError(t, err)

	got, err := db.GetCalendarEventByID("evt1")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "Team Standup", got.Title)
	assert.Equal(t, "Daily standup", got.Description)
	assert.Equal(t, "Room 42", got.Location)
	assert.Equal(t, "2026-04-02T09:00:00Z", got.StartTime)
	assert.Equal(t, "alice@example.com", got.OrganizerEmail)
	assert.True(t, got.IsRecurring)
	assert.Equal(t, "default", got.EventType)
	assert.Equal(t, "evt1@google.com", got.ICalUID)
}

func TestGetCalendarEventByID_NotFound(t *testing.T) {
	db := openTestDB(t)

	got, err := db.GetCalendarEventByID("nonexistent")
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestGetCalendarEvents_Filter(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "cal1", Name: "C1", SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "cal2", Name: "C2", SyncedAt: "2026-04-01T00:00:00Z"}))

	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: "e1", CalendarID: "cal1", Title: "Morning", StartTime: "2026-04-02T08:00:00Z", EndTime: "2026-04-02T09:00:00Z"}))
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: "e2", CalendarID: "cal1", Title: "Afternoon", StartTime: "2026-04-02T14:00:00Z", EndTime: "2026-04-02T15:00:00Z"}))
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: "e3", CalendarID: "cal2", Title: "Other Cal", StartTime: "2026-04-02T10:00:00Z", EndTime: "2026-04-02T11:00:00Z"}))

	// All events.
	all, err := db.GetCalendarEvents(CalendarEventFilter{})
	require.NoError(t, err)
	assert.Len(t, all, 3)

	// Filter by calendar.
	cal1Events, err := db.GetCalendarEvents(CalendarEventFilter{CalendarID: "cal1"})
	require.NoError(t, err)
	assert.Len(t, cal1Events, 2)

	// Filter by time range.
	morning, err := db.GetCalendarEvents(CalendarEventFilter{
		FromTime: "2026-04-02T07:00:00Z",
		ToTime:   "2026-04-02T09:30:00Z",
	})
	require.NoError(t, err)
	assert.Len(t, morning, 1)
	assert.Equal(t, "Morning", morning[0].Title)

	// Limit.
	limited, err := db.GetCalendarEvents(CalendarEventFilter{Limit: 1})
	require.NoError(t, err)
	assert.Len(t, limited, 1)
}

func TestGetCalendarEventsForDate(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: "2026-04-01T00:00:00Z"}))

	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: "e1", CalendarID: "primary", Title: "Today", StartTime: "2026-04-02T10:00:00Z", EndTime: "2026-04-02T11:00:00Z"}))
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: "e2", CalendarID: "primary", Title: "Tomorrow", StartTime: "2026-04-03T10:00:00Z", EndTime: "2026-04-03T11:00:00Z"}))

	events, err := db.GetCalendarEventsForDate("2026-04-02", time.UTC)
	require.NoError(t, err)
	assert.Len(t, events, 1)
	assert.Equal(t, "Today", events[0].Title)
}

// The day window is the LOCAL day (converted to UTC for the timed-event
// comparison), and an all-day event — stored as UTC midnight with an exclusive
// end — matches only its own date, never the day after (its end == that day's
// midnight) or, in a negative-offset zone, the day before.
func TestGetCalendarEventsForDate_LocalDayAndAllDayBoundaries(t *testing.T) {
	for _, zone := range []string{"America/Los_Angeles", "Asia/Tokyo", "UTC"} {
		t.Run(zone, func(t *testing.T) {
			loc, err := time.LoadLocation(zone)
			require.NoError(t, err)
			db := openTestDB(t)
			require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: time.Now().UTC().Format(time.RFC3339)}))

			now := time.Now().In(loc)
			day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)
			date := day.Format("2006-01-02")
			utcDate := func(offsetDays int) string { return day.AddDate(0, 0, offsetDays).Format("2006-01-02") + "T00:00:00Z" }
			ts := func(tm time.Time) string { return tm.UTC().Format(time.RFC3339) }

			for _, ev := range []CalendarEvent{
				{ID: "allday-yesterday", StartTime: utcDate(-1), EndTime: utcDate(0), IsAllDay: true},
				{ID: "allday-today", StartTime: utcDate(0), EndTime: utcDate(1), IsAllDay: true},
				{ID: "allday-tomorrow", StartTime: utcDate(1), EndTime: utcDate(2), IsAllDay: true},
				{ID: "late-evening", StartTime: ts(day.Add(22 * time.Hour)), EndTime: ts(day.Add(23 * time.Hour))},
				{ID: "early-morning", StartTime: ts(day.Add(30 * time.Minute)), EndTime: ts(day.Add(90 * time.Minute))},
				{ID: "prev-evening", StartTime: ts(day.Add(-2 * time.Hour)), EndTime: ts(day.Add(-1 * time.Hour))},
				{ID: "ends-at-midnight", StartTime: ts(day.Add(-time.Hour)), EndTime: ts(day)},
				{ID: "next-morning", StartTime: ts(day.Add(25 * time.Hour)), EndTime: ts(day.Add(26 * time.Hour))},
				{ID: "overnight", StartTime: ts(day.Add(-time.Hour)), EndTime: ts(day.Add(time.Hour))},
			} {
				ev.CalendarID, ev.Title = "primary", ev.ID
				require.NoError(t, db.UpsertCalendarEvent(ev))
			}

			events, err := db.GetCalendarEventsForDate(date, loc)
			require.NoError(t, err)
			var got []string
			for _, e := range events {
				got = append(got, e.ID)
			}
			assert.ElementsMatch(t, []string{"allday-today", "early-morning", "late-evening", "overnight"}, got)
		})
	}
}

// A DST transition day is 23 or 25 hours long; the window must follow the
// local calendar day, not a fixed 24h. Fixed past dates are fine here: this is
// pure window arithmetic, not a date bomb.
func TestGetCalendarEventsForDate_DSTTransitionDays(t *testing.T) {
	loc, err := time.LoadLocation("America/Los_Angeles")
	require.NoError(t, err)
	for _, date := range []string{"2026-03-08", "2026-11-01"} {
		t.Run(date, func(t *testing.T) {
			db := openTestDB(t)
			require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: time.Now().UTC().Format(time.RFC3339)}))
			day, err := time.ParseInLocation("2006-01-02", date, loc)
			require.NoError(t, err)
			next := day.AddDate(0, 0, 1)
			ts := func(tm time.Time) string { return tm.UTC().Format(time.RFC3339) }
			for _, ev := range []CalendarEvent{
				// On the 23h day, next-early falls inside a fixed day+24h window;
				// on the 25h day, late falls outside it. Only the local-day
				// window gets both right.
				{ID: "late", StartTime: ts(next.Add(-30 * time.Minute)), EndTime: ts(next.Add(-10 * time.Minute))},
				{ID: "next-early", StartTime: ts(next.Add(10 * time.Minute)), EndTime: ts(next.Add(40 * time.Minute))},
				{ID: "prev-late", StartTime: ts(day.Add(-40 * time.Minute)), EndTime: ts(day.Add(-10 * time.Minute))},
			} {
				ev.CalendarID, ev.Title = "primary", ev.ID
				require.NoError(t, db.UpsertCalendarEvent(ev))
			}
			events, err := db.GetCalendarEventsForDate(date, loc)
			require.NoError(t, err)
			var got []string
			for _, e := range events {
				got = append(got, e.ID)
			}
			assert.Equal(t, []string{"late"}, got)
			assert.NotEqual(t, 24*time.Hour, next.Sub(day), "the fixture really is a DST transition day")
		})
	}
}

func TestGetCalendarEventsForDate_BadDate(t *testing.T) {
	db := openTestDB(t)
	_, err := db.GetCalendarEventsForDate("not-a-date", time.UTC)
	assert.Error(t, err)
}

func TestGetNextEvent(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: "2026-04-01T00:00:00Z"}))

	// Event in the far future (should be returned).
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: "future", CalendarID: "primary", Title: "Future Event", StartTime: "2099-01-01T10:00:00Z", EndTime: "2099-01-01T11:00:00Z"}))

	ev, err := db.GetNextEvent()
	require.NoError(t, err)
	require.NotNil(t, ev)
	assert.Equal(t, "Future Event", ev.Title)
}

func TestUpsertCalendarEvents_Batch(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: "2026-04-01T00:00:00Z"}))

	events := []CalendarEvent{
		{ID: "b1", CalendarID: "primary", Title: "Event 1", StartTime: "2026-04-02T08:00:00Z", EndTime: "2026-04-02T09:00:00Z", ICalUID: "b1@google.com"},
		{ID: "b2", CalendarID: "primary", Title: "Event 2", StartTime: "2026-04-02T10:00:00Z", EndTime: "2026-04-02T11:00:00Z"},
	}

	err := db.UpsertCalendarEvents(events)
	require.NoError(t, err)

	all, err := db.GetCalendarEvents(CalendarEventFilter{})
	require.NoError(t, err)
	assert.Len(t, all, 2)

	got, err := db.GetCalendarEventByID("b1")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "b1@google.com", got.ICalUID)
}

// TestUpsertCalendarEvent_PreservesFKChildren guards the sync-cycle wipe bug:
// calendar_events upserts must never be INSERT OR REPLACE. With foreign_keys=ON
// a REPLACE on a PK conflict is DELETE+INSERT, which fires the FK actions on
// the children — meeting_transcripts.event_id (ON DELETE SET NULL) loses its
// link and the event's meeting_recaps row (ON DELETE CASCADE) is physically
// deleted, on EVERY sync cycle that re-upserts the window's events.
func TestUpsertCalendarEvent_PreservesFKChildren(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{
		ID: "evt-fk", CalendarID: "primary", Title: "Planning",
		StartTime: "2026-04-02T09:00:00Z", EndTime: "2026-04-02T10:00:00Z",
	}))

	transcriptID, err := db.InsertMeetingTranscript(MeetingTranscript{
		EventID:        sql.NullString{String: "evt-fk", Valid: true},
		Title:          "Planning",
		TranscriptText: "hello world",
	})
	require.NoError(t, err)
	require.NoError(t, db.UpsertMeetingRecap("evt-fk", "hello world", `{"summary":"ok"}`, 0))

	// Per-path assertions so a REPLACE regression in either call site fails on
	// its own step, not only via the combined end state.
	assertChildrenIntact := func(path string) {
		t.Helper()
		tr, err := db.GetMeetingTranscript(transcriptID)
		require.NoError(t, err)
		require.NotNil(t, tr)
		assert.True(t, tr.EventID.Valid, "transcript event link must survive an event re-upsert (%s)", path)
		assert.Equal(t, "evt-fk", tr.EventID.String)
		recap, err := db.GetMeetingRecap("evt-fk")
		require.NoError(t, err)
		require.NotNil(t, recap, "meeting recap must survive an event re-upsert (%s)", path)
	}

	// Re-upsert the same event id with changed fields — a normal sync cycle,
	// using the explicit-syncedAt branch the calendar/CalDAV syncers call.
	// The stale-event cleanup deletes rows with synced_at < the sync's stamp,
	// so excluded.synced_at must carry the explicit value through the UPDATE
	// branch — a stale synced_at here re-opens the wipe via the delete path.
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{
		ID: "evt-fk", CalendarID: "primary", Title: "Planning (moved)",
		StartTime: "2026-04-02T11:00:00Z", EndTime: "2026-04-02T12:00:00Z",
	}, "2026-04-03T08:00:00Z"))
	got, err := db.GetCalendarEventByID("evt-fk")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "Planning (moved)", got.Title)
	assert.Equal(t, "2026-04-03T08:00:00Z", got.SyncedAt,
		"explicit syncedAt must be refreshed on the conflict-update branch")
	assertChildrenIntact("single path")

	// And again through the batch path (strftime-now synced_at).
	require.NoError(t, db.UpsertCalendarEvents([]CalendarEvent{{
		ID: "evt-fk", CalendarID: "primary", Title: "Planning (moved again)",
		StartTime: "2026-04-02T13:00:00Z", EndTime: "2026-04-02T14:00:00Z",
	}}))
	got, err = db.GetCalendarEventByID("evt-fk")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "Planning (moved again)", got.Title)
	assert.Equal(t, "2026-04-02T13:00:00Z", got.StartTime)
	assert.NotEqual(t, "2026-04-03T08:00:00Z", got.SyncedAt,
		"batch upsert must restamp synced_at on the conflict-update branch")
	assertChildrenIntact("batch path")
}

func TestDeleteStaleCalendarEvents(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: "2026-04-01T00:00:00Z"}))

	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: "old", CalendarID: "primary", Title: "Old", StartTime: "2026-04-02T08:00:00Z", EndTime: "2026-04-02T09:00:00Z"}))

	// Delete events synced before a future timestamp (should delete all).
	n, err := db.DeleteStaleCalendarEvents("primary", "2099-01-01T00:00:00Z")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	all, err := db.GetCalendarEvents(CalendarEventFilter{})
	require.NoError(t, err)
	assert.Empty(t, all)
}

// TestDeleteStaleCalendarEvents_SparesReferencedEvents pins owner decision 14:
// an event still referenced by a meeting_transcripts or meeting_recaps row
// must survive stale-cleanup even though its synced_at is old, because the
// association is what regenerated recap/notes/chapters and the attendee
// voice-print pool depend on. Every combination of the two references is its
// own row so a guard scoped to only one table, or one using OR instead of
// AND, is caught (see docs/superpowers/plans/2026-09-13-audit-fix-wave5.md,
// Task 3): a recap-only event (the paste flow creates recaps with no
// transcript) is the cell a transcript-only NOT EXISTS would miss.
//
// The fixture also seeds an ad-hoc transcript and an already-detached recap,
// both with a NULL event_id — the first-class product states of "recorded
// without a calendar event" and "the event was already deleted" (the whole
// premise of migration 00056). Without them, every meeting_transcripts /
// meeting_recaps row in the fixture has a non-NULL event_id, so a
// `calendar_events.id NOT IN (SELECT event_id FROM meeting_transcripts)`
// spelling (SQL's classic NULL trap: one NULL in the subquery makes NOT IN
// evaluate to NULL/false for every row) would pass this whole test while, on
// a live install, silently stopping stale-cleanup from ever deleting
// anything again.
func TestDeleteStaleCalendarEvents_SparesReferencedEvents(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "other", Name: "Other", SyncedAt: "2026-04-01T00:00:00Z"}))

	stale := "2026-04-02T08:00:00Z"
	staleEnd := "2026-04-02T09:00:00Z"

	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{
		ID: "evt-plain", CalendarID: "primary", Title: "Plain", StartTime: stale, EndTime: staleEnd,
	}))
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{
		ID: "evt-transcript", CalendarID: "primary", Title: "Transcript only", StartTime: stale, EndTime: staleEnd,
	}))
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{
		ID: "evt-recap", CalendarID: "primary", Title: "Recap only", StartTime: stale, EndTime: staleEnd,
	}))
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{
		ID: "evt-both", CalendarID: "primary", Title: "Both", StartTime: stale, EndTime: staleEnd,
	}))
	// Fifth row under a different calendar_id — must never be touched by a
	// primary-calendar cleanup call, guarding against a rewrite that drops
	// the calendar_id scope.
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{
		ID: "evt-other-calendar", CalendarID: "other", Title: "Other calendar", StartTime: stale, EndTime: staleEnd,
	}))

	_, err := db.InsertMeetingTranscript(MeetingTranscript{
		EventID: sql.NullString{String: "evt-transcript", Valid: true}, Title: "T1", TranscriptText: "hello",
	})
	require.NoError(t, err)
	transcriptForBoth, err := db.InsertMeetingTranscript(MeetingTranscript{
		EventID: sql.NullString{String: "evt-both", Valid: true}, Title: "T2", TranscriptText: "hello",
	})
	require.NoError(t, err)

	require.NoError(t, db.UpsertMeetingRecap("evt-recap", "source", "{}", 0))
	require.NoError(t, db.UpsertMeetingRecap("evt-both", "source", "{}", transcriptForBoth))

	// An ad-hoc recording (never linked to any calendar event) and an
	// already-detached recap (its event already gone, event_id SET NULL by
	// the FK — the 00056 scenario). Neither references any of the fixture's
	// events, but both must keep event_id NULL in the tables a NOT EXISTS
	// correlates against, poisoning a NOT IN rewrite for every row.
	_, err = db.InsertMeetingTranscript(MeetingTranscript{Title: "Ad-hoc", TranscriptText: "hello"})
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO meeting_recaps (event_id, source_text, recap_json) VALUES (NULL, ?, ?)`, "source", "{}")
	require.NoError(t, err)

	cutoff := "2099-01-01T00:00:00Z"

	n, err := db.DeleteStaleCalendarEvents("primary", cutoff)
	require.NoError(t, err)
	assert.Equal(t, 1, n, "exactly the unreferenced event must be deleted")

	assertEventExists := func(id string, want bool, msg string) {
		t.Helper()
		got, err := db.GetCalendarEventByID(id)
		require.NoError(t, err)
		if want {
			assert.NotNilf(t, got, "%s: %s should survive", msg, id)
		} else {
			assert.Nilf(t, got, "%s: %s should be deleted", msg, id)
		}
	}

	assertEventExists("evt-plain", false, "unreferenced")
	assertEventExists("evt-transcript", true, "transcript-only")
	assertEventExists("evt-recap", true, "recap-only")
	assertEventExists("evt-both", true, "transcript and recap")
	assertEventExists("evt-other-calendar", true, "different calendar, never in scope")

	// Idempotency: a second pass over the same cutoff deletes nothing more.
	n, err = db.DeleteStaleCalendarEvents("primary", cutoff)
	require.NoError(t, err)
	assert.Equal(t, 0, n, "second pass must be a no-op: the survivors are still referenced")

	assertEventExists("evt-transcript", true, "second pass, transcript-only")
	assertEventExists("evt-recap", true, "second pass, recap-only")
	assertEventExists("evt-both", true, "second pass, transcript and recap")
}

// TestClearGoogleAccountCalendarData pins the scope of `calendar logout`:
// only the given Google account's calendars and events go, never another
// Google account's, never a CalDAV/ICS calendar (NULL account_id), never the
// shared attendee cache — and an event a recording or recap still references
// survives (owner decision 14, the DeleteStaleCalendarEvents guard), keeping
// its calendar row so the event's foreign key stays valid.
func TestClearGoogleAccountCalendarData(t *testing.T) {
	db := openTestDB(t)

	acctA, err := db.CreateGoogleAccount(GoogleAccount{Email: "a@example.com", Label: "A", CalendarEnabled: true})
	require.NoError(t, err)
	acctB, err := db.CreateGoogleAccount(GoogleAccount{Email: "b@example.com", Label: "B", CalendarEnabled: true})
	require.NoError(t, err)

	start := time.Now().UTC().Add(24 * time.Hour).Format(time.RFC3339)
	end := time.Now().UTC().Add(25 * time.Hour).Format(time.RFC3339)
	calendars := []struct {
		account int64
		id      string
	}{
		{acctA, "a-primary"},
		{acctA, "a-team"},
		{acctA, "a-recorded"},
		{acctB, "b-primary"},
		{0, "caldav:work"},
		{0, "ics:holidays"},
	}
	for _, c := range calendars {
		require.NoError(t, db.UpsertCalendar(c.account, CalendarCalendar{ID: c.id, Name: c.id, IsSelected: true, SyncedAt: start}))
	}
	events := map[string]string{
		"evt-a1":         "a-primary",
		"evt-a2":         "a-team",
		"evt-a-recorded": "a-recorded",
		"evt-a-recapped": "a-recorded",
		"evt-a-unlinked": "a-recorded",
		"evt-b":          "b-primary",
		"evt-caldav":     "caldav:work",
		"evt-ics":        "ics:holidays",
	}
	for id, cal := range events {
		require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: id, CalendarID: cal, Title: id, StartTime: start, EndTime: end}))
	}
	_, err = db.InsertMeetingTranscript(MeetingTranscript{
		EventID: sql.NullString{String: "evt-a-recorded", Valid: true}, Title: "T", TranscriptText: "hello",
	})
	require.NoError(t, err)
	require.NoError(t, db.UpsertMeetingRecap("evt-a-recapped", "source", "{}", 0))
	// An ad-hoc recording keeps a NULL event_id in the table the guard
	// correlates against — it must not poison the guard into sparing nothing.
	_, err = db.InsertMeetingTranscript(MeetingTranscript{Title: "Ad-hoc", TranscriptText: "hello"})
	require.NoError(t, err)
	require.NoError(t, db.UpsertAttendeeMap("alice@example.com", "U123"))

	n, err := db.ClearGoogleAccountCalendarData(acctA)
	require.NoError(t, err)
	assert.Equal(t, 3, n, "evt-a1, evt-a2 and evt-a-unlinked are deleted")

	for id, want := range map[string]bool{
		"evt-a1":         false,
		"evt-a2":         false,
		"evt-a-unlinked": false,
		"evt-a-recorded": true,
		"evt-a-recapped": true,
		"evt-b":          true,
		"evt-caldav":     true,
		"evt-ics":        true,
	} {
		got, err := db.GetCalendarEventByID(id)
		require.NoError(t, err)
		assert.Equalf(t, want, got != nil, "event %s survives = %v", id, want)
	}

	var transcriptEvent sql.NullString
	require.NoError(t, db.QueryRow(`SELECT event_id FROM meeting_transcripts WHERE title = 'T'`).Scan(&transcriptEvent))
	assert.Equal(t, "evt-a-recorded", transcriptEvent.String, "the recording stays linked to its event")

	cals, err := db.GetCalendars()
	require.NoError(t, err)
	got := map[string]bool{}
	for _, c := range cals {
		got[c.ID] = c.IsSelected
	}
	assert.Equal(t, map[string]bool{
		"a-recorded":   true, // still holds referenced events
		"b-primary":    true, // selection of another account is untouched
		"caldav:work":  true,
		"ics:holidays": true,
	}, got)

	m, err := db.GetAttendeeMap()
	require.NoError(t, err)
	assert.Equal(t, "U123", m["alice@example.com"], "the attendee cache is shared across accounts and kept")

	// Idempotent: a second pass deletes nothing more.
	n, err = db.ClearGoogleAccountCalendarData(acctA)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
}

func TestAttendeeMap(t *testing.T) {
	db := openTestDB(t)

	err := db.UpsertAttendeeMap("alice@example.com", "U123")
	require.NoError(t, err)

	err = db.UpsertAttendeeMap("bob@example.com", "U456")
	require.NoError(t, err)

	// Get full map.
	m, err := db.GetAttendeeMap()
	require.NoError(t, err)
	assert.Len(t, m, 2)
	assert.Equal(t, "U123", m["alice@example.com"])
	assert.Equal(t, "U456", m["bob@example.com"])

	// Get by email.
	uid, err := db.GetSlackUserIDByEmail("alice@example.com")
	require.NoError(t, err)
	assert.Equal(t, "U123", uid)

	// Overwrite.
	err = db.UpsertAttendeeMap("alice@example.com", "U999")
	require.NoError(t, err)

	uid, err = db.GetSlackUserIDByEmail("alice@example.com")
	require.NoError(t, err)
	assert.Equal(t, "U999", uid)
}
