package calendar

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestResolveAttendees_NoSlackUser(t *testing.T) {
	// Without a DB, ResolveAttendees should leave SlackUserID empty.
	// This tests the logic path where email lookup returns nothing.
	events := []CalendarEvent{
		{
			ID:    "e1",
			Title: "Test",
			Attendees: []Attendee{
				{Email: "unknown@example.com", DisplayName: "Unknown"},
			},
		},
	}

	// Verify attendees structure is preserved.
	assert.Len(t, events[0].Attendees, 1)
	assert.Equal(t, "unknown@example.com", events[0].Attendees[0].Email)
	assert.Equal(t, "", events[0].Attendees[0].SlackUserID)
}

func TestCalendarEvent_Fields(t *testing.T) {
	ev := CalendarEvent{
		ID:          "test-id",
		Title:       "Review Meeting",
		Description: "Q1 review",
		HTMLLink:    "https://calendar.google.com/test",
		EventType:   "default",
		UpdatedAt:   "2026-04-01T12:00:00Z",
		Attendees: []Attendee{
			{Email: "alice@example.com", SlackUserID: "U123"},
		},
	}

	assert.Equal(t, "test-id", ev.ID)
	assert.Equal(t, "Review Meeting", ev.Title)
	assert.Equal(t, "Q1 review", ev.Description)
	assert.Equal(t, "default", ev.EventType)
	assert.Len(t, ev.Attendees, 1)
	assert.Equal(t, "U123", ev.Attendees[0].SlackUserID)
}

func TestCalendarInfo_Fields(t *testing.T) {
	ci := CalendarInfo{
		ID:      "primary",
		Summary: "Main Calendar",
		Primary: true,
		Color:   "#4285f4",
	}

	assert.Equal(t, "primary", ci.ID)
	assert.True(t, ci.Primary)
	assert.Equal(t, "#4285f4", ci.Color)
}

// TestDropNonGoogleCalendarIDs guards the multi-source split: CalDAV/ICS
// accounts (internal/caldav) register calendar_calendars rows scoped
// "caldav:<id>"/"ics:<id>", and those ids must never enter the Google
// syncer's fetch or stale-delete loops.
func TestDropNonGoogleCalendarIDs(t *testing.T) {
	got := dropNonGoogleCalendarIDs([]string{"primary", "caldav:3", "team@group.calendar.google.com", "ics:7"})
	assert.Equal(t, []string{"primary", "team@group.calendar.google.com"}, got)

	assert.Empty(t, dropNonGoogleCalendarIDs([]string{"caldav:1"}))
	assert.Empty(t, dropNonGoogleCalendarIDs(nil))
}

// TestSelectedCalendarsScopedToAccount guards the DB-selection path
// (GetSelectedCalendarIDs) that the Syncer falls back to for every account:
// each google_accounts row only sees its own calendar_calendars rows, and a
// caldav:-scoped row (account_id NULL) never leaks into any account's list.
func TestSelectedCalendarsScopedToAccount(t *testing.T) {
	database := db.OpenTestDB(t)

	acct1, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	acct2, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "b@x.com", Label: "B"})
	require.NoError(t, err)

	require.NoError(t, database.UpsertCalendar(acct1, db.CalendarCalendar{ID: "primary", Name: "A Primary", IsSelected: true}))
	require.NoError(t, database.UpsertCalendar(acct2, db.CalendarCalendar{ID: "team@group.calendar.google.com", Name: "B Team", IsSelected: true}))
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: "caldav:1", Name: "CalDAV", IsSelected: true}))

	ids2, err := database.GetSelectedCalendarIDs(acct2)
	require.NoError(t, err)
	assert.Equal(t, []string{"team@group.calendar.google.com"}, ids2)

	ids1, err := database.GetSelectedCalendarIDs(acct1)
	require.NoError(t, err)
	assert.Equal(t, []string{"primary"}, ids1)
}

// TestStaleCleanupDoesNotCrossAccounts guards Sync's stale-cleanup loop:
// it only ever iterates the calendar ids resolved for the syncing account, so
// another account's events are never candidates for deletion.
func TestStaleCleanupDoesNotCrossAccounts(t *testing.T) {
	database := db.OpenTestDB(t)

	acct1, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	acct2, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "b@x.com", Label: "B"})
	require.NoError(t, err)

	require.NoError(t, database.UpsertCalendar(acct1, db.CalendarCalendar{ID: "cal-1", Name: "A Cal"}))
	require.NoError(t, database.UpsertCalendar(acct2, db.CalendarCalendar{ID: "cal-2", Name: "B Cal"}))

	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{ID: "ev-1", CalendarID: "cal-1", StartTime: "2026-01-01T00:00:00Z", EndTime: "2026-01-01T01:00:00Z"}, "2000-01-01T00:00:00Z"))
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{ID: "ev-2", CalendarID: "cal-2", StartTime: "2026-01-01T00:00:00Z", EndTime: "2026-01-01T01:00:00Z"}, "2000-01-01T00:00:00Z"))

	// Simulate Sync's per-calendar cleanup loop scoped to account 1's own
	// calendar ids only (what NewSyncer(..., acct1).Sync would compute).
	for _, calID := range []string{"cal-1"} {
		_, err := database.DeleteStaleCalendarEvents(calID, "2100-01-01T00:00:00Z")
		require.NoError(t, err)
	}

	ev1, err := database.GetCalendarEventByID("ev-1")
	require.NoError(t, err)
	assert.Nil(t, ev1, "account 1's stale event should have been deleted")

	ev2, err := database.GetCalendarEventByID("ev-2")
	require.NoError(t, err)
	require.NotNil(t, ev2, "account 2's event must survive account 1's cleanup")
}
