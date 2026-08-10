package db

import (
	"database/sql"
	"testing"

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

	events, err := db.GetCalendarEventsForDate("2026-04-02")
	require.NoError(t, err)
	assert.Len(t, events, 1)
	assert.Equal(t, "Today", events[0].Title)
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
	require.NoError(t, db.UpsertMeetingRecap("evt-fk", "hello world", `{"summary":"ok"}`))

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

func TestClearCalendarEvents(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "primary", Name: "Main", SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{ID: "e1", CalendarID: "primary", Title: "E1", StartTime: "2026-04-02T08:00:00Z", EndTime: "2026-04-02T09:00:00Z"}))
	require.NoError(t, db.UpsertAttendeeMap("alice@example.com", "U123"))

	err := db.ClearCalendarEvents()
	require.NoError(t, err)

	cals, _ := db.GetCalendars()
	assert.Empty(t, cals)

	events, _ := db.GetCalendarEvents(CalendarEventFilter{})
	assert.Empty(t, events)

	m, _ := db.GetAttendeeMap()
	assert.Empty(t, m)
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
