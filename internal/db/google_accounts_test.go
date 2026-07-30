package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestGoogleAccountCreateListGetRoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateGoogleAccount(GoogleAccount{
		Email: "a@x.com", Label: "Work", ClientID: "client-123",
		CalendarEnabled: true, GmailEnabled: false,
	})
	require.NoError(t, err)
	assert.Equal(t, int64(1), id)

	id2, err := d.CreateGoogleAccount(GoogleAccount{Email: "b@y.com", Label: "Personal"})
	require.NoError(t, err)
	assert.Equal(t, int64(2), id2)

	accounts, err := d.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 2)
	// ORDER BY id ASC
	assert.Equal(t, id, accounts[0].ID)
	assert.Equal(t, "a@x.com", accounts[0].Email)
	assert.Equal(t, "Work", accounts[0].Label)
	assert.Equal(t, "client-123", accounts[0].ClientID)
	assert.True(t, accounts[0].CalendarEnabled)
	assert.False(t, accounts[0].GmailEnabled)
	assert.Equal(t, "ok", accounts[0].Status)
	assert.NotEmpty(t, accounts[0].CreatedAt)
	assert.NotEmpty(t, accounts[0].UpdatedAt)
	assert.Equal(t, id2, accounts[1].ID)
	assert.Equal(t, "b@y.com", accounts[1].Email)

	got, err := d.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "a@x.com", got.Email)
	assert.Equal(t, "Work", got.Label)

	_, err = d.GetGoogleAccount(999)
	assert.Error(t, err)
}

func TestGoogleAccount_UpdateConnection(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateGoogleAccount(GoogleAccount{Email: "", Label: "New"})
	require.NoError(t, err)

	require.NoError(t, d.UpdateGoogleAccountConnection(id, "resolved@x.com", true, true))

	got, err := d.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "resolved@x.com", got.Email)
	assert.True(t, got.CalendarEnabled)
	assert.True(t, got.GmailEnabled)
}

// TestGoogleAccount_SetAuthState_MissingRow mirrors SetEmailAccountAuthState's
// RowsAffected()==0 error shape (email_accounts.go:195) for a missing row.
func TestGoogleAccount_SetAuthState_MissingRow(t *testing.T) {
	d := openTestDB(t)

	err := d.SetGoogleAccountAuthState(999, "error", "boom")
	require.Error(t, err)
}

func TestGoogleAccount_SetAuthState_RoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "Work"})
	require.NoError(t, err)

	require.NoError(t, d.SetGoogleAccountAuthState(id, "revoked", "token expired"))

	got, err := d.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "revoked", got.Status)
	assert.Equal(t, "token expired", got.Error)
}

// TestGoogleAccount_GmailWatermark_MissingRowReturnsZero mirrors
// GetImapWatermark's (0, nil) shape (email_accounts.go:167) for a missing row.
func TestGoogleAccount_GmailWatermark_MissingRowReturnsZero(t *testing.T) {
	d := openTestDB(t)

	ts, err := d.GetGmailAccountWatermark(999)
	require.NoError(t, err)
	assert.Zero(t, ts)
}

func TestGoogleAccount_GmailWatermark_RoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "Work"})
	require.NoError(t, err)

	ts, err := d.GetGmailAccountWatermark(id)
	require.NoError(t, err)
	assert.Zero(t, ts)

	require.NoError(t, d.SetGmailAccountWatermark(id, 12345.5))

	ts, err = d.GetGmailAccountWatermark(id)
	require.NoError(t, err)
	assert.Equal(t, 12345.5, ts)
}

func TestGoogleAccount_MemoryGmailWatermark_RoundTrip(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "Work"})
	require.NoError(t, err)

	ts, err := d.MemoryGmailWatermark(id)
	require.NoError(t, err)
	assert.Zero(t, ts)

	require.NoError(t, d.SetMemoryGmailWatermark(id, 987.0))

	ts, err = d.MemoryGmailWatermark(id)
	require.NoError(t, err)
	assert.Equal(t, 987.0, ts)
}

func TestGoogleAccount_MemoryGmailWatermark_MissingRowReturnsZero(t *testing.T) {
	d := openTestDB(t)

	ts, err := d.MemoryGmailWatermark(999)
	require.NoError(t, err)
	assert.Zero(t, ts)
}

// TestGoogleAccount_DeleteGoogleAccount_ScopedToOwnCalendars mirrors
// DeleteCalendarAccount's transaction shape (calendar_accounts.go:90):
// deleting one account's calendars + events must leave another account's
// calendars and events untouched.
func TestGoogleAccount_DeleteGoogleAccount_ScopedToOwnCalendars(t *testing.T) {
	d := openTestDB(t)

	id1, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	id2, err := d.CreateGoogleAccount(GoogleAccount{Email: "b@y.com", Label: "B"})
	require.NoError(t, err)

	require.NoError(t, d.UpsertCalendar(id1, CalendarCalendar{ID: "cal1", Name: "Cal 1", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, d.UpsertCalendar(id2, CalendarCalendar{ID: "cal2", Name: "Cal 2", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))

	require.NoError(t, d.UpsertCalendarEvent(CalendarEvent{ID: "evt1", CalendarID: "cal1", Title: "Meeting 1", StartTime: "2026-04-01T10:00:00Z", EndTime: "2026-04-01T11:00:00Z"}))
	require.NoError(t, d.UpsertCalendarEvent(CalendarEvent{ID: "evt2", CalendarID: "cal2", Title: "Meeting 2", StartTime: "2026-04-01T10:00:00Z", EndTime: "2026-04-01T11:00:00Z"}))

	require.NoError(t, d.DeleteGoogleAccount(id1))

	// Account 1's calendar and event are gone.
	cals, err := d.GetCalendars()
	require.NoError(t, err)
	var ids []string
	for _, c := range cals {
		ids = append(ids, c.ID)
	}
	assert.NotContains(t, ids, "cal1")
	assert.Contains(t, ids, "cal2")

	evt1, err := d.GetCalendarEventByID("evt1")
	require.NoError(t, err)
	assert.Nil(t, evt1)

	// Account 2's calendar and event are untouched.
	evt2, err := d.GetCalendarEventByID("evt2")
	require.NoError(t, err)
	require.NotNil(t, evt2)
	assert.Equal(t, "Meeting 2", evt2.Title)

	_, err = d.GetGoogleAccount(id1)
	assert.Error(t, err)
	_, err = d.GetGoogleAccount(id2)
	assert.NoError(t, err)
}

func TestGoogleAccount_DeleteGoogleAccount_MissingIsNoop(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.DeleteGoogleAccount(999))
}

// TestGoogleAccount_GetSelectedCalendarIDs_ScopedAndExcludesNonGoogle covers
// GetSelectedCalendarIDs(accountID): only the given account's selected
// calendars, never caldav:/ics: rows (which carry a NULL account_id).
func TestGoogleAccount_GetSelectedCalendarIDs_ScopedAndExcludesNonGoogle(t *testing.T) {
	d := openTestDB(t)

	id1, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	id2, err := d.CreateGoogleAccount(GoogleAccount{Email: "b@y.com", Label: "B"})
	require.NoError(t, err)

	require.NoError(t, d.UpsertCalendar(id1, CalendarCalendar{ID: "cal-a1", Name: "A1", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, d.UpsertCalendar(id2, CalendarCalendar{ID: "cal-b1", Name: "B1", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, d.UpsertCalendar(id2, CalendarCalendar{ID: "cal-b2", Name: "B2", IsSelected: false, SyncedAt: "2026-04-01T00:00:00Z"}))
	// NULL account_id, as caldav/ics rows always get.
	require.NoError(t, d.UpsertCalendar(0, CalendarCalendar{ID: "caldav:1", Name: "CalDAV", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z"}))

	ids, err := d.GetSelectedCalendarIDs(id2)
	require.NoError(t, err)
	assert.Equal(t, []string{"cal-b1"}, ids)

	ids, err = d.GetSelectedCalendarIDs(id1)
	require.NoError(t, err)
	assert.Equal(t, []string{"cal-a1"}, ids)
}
