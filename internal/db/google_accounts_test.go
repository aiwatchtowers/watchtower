package db

import (
	"database/sql"
	"testing"
	"time"

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

// TestGoogleAccount_SetMemoryGmailWatermark_MissingRow mirrors
// TestGoogleAccount_SetAuthState_MissingRow's RowsAffected()==0 error shape
// (a deferred gap from Task 2, closed here since SetMemoryGmailWatermark
// gained per-account callers in Task 9).
func TestGoogleAccount_SetMemoryGmailWatermark_MissingRow(t *testing.T) {
	d := openTestDB(t)

	err := d.SetMemoryGmailWatermark(999, 123.0)
	require.Error(t, err)
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

// TestGoogleAccount_DeleteGoogleAccount_SparesRecordedEvents pins that
// `google remove` never unlinks a recording or recap from its event: an event
// a meeting_transcripts or meeting_recaps row references survives (the
// DeleteStaleCalendarEvents guard, owner decision 14), and so does the
// calendar row holding it — detached from the deleted account (account_id
// NULL, is_selected 0) since the account row itself goes. Everything else of
// the account is deleted as before, and another account is untouched.
func TestGoogleAccount_DeleteGoogleAccount_SparesRecordedEvents(t *testing.T) {
	d := openTestDB(t)

	idA, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@example.com", Label: "A"})
	require.NoError(t, err)
	idB, err := d.CreateGoogleAccount(GoogleAccount{Email: "b@example.com", Label: "B"})
	require.NoError(t, err)

	start := time.Now().UTC().Add(-2 * time.Hour).Format(time.RFC3339)
	end := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	for _, c := range []struct {
		account int64
		id      string
	}{{idA, "a-plain"}, {idA, "a-recorded"}, {idB, "b-primary"}} {
		require.NoError(t, d.UpsertCalendar(c.account, CalendarCalendar{ID: c.id, Name: c.id, IsSelected: true, SyncedAt: start}))
	}
	for id, cal := range map[string]string{
		"evt-plain":    "a-plain",
		"evt-recorded": "a-recorded",
		"evt-recapped": "a-recorded",
		"evt-unlinked": "a-recorded",
		"evt-b":        "b-primary",
	} {
		require.NoError(t, d.UpsertCalendarEvent(CalendarEvent{ID: id, CalendarID: cal, Title: id, StartTime: start, EndTime: end}))
	}
	tid, err := d.InsertMeetingTranscript(MeetingTranscript{
		EventID: sql.NullString{String: "evt-recorded", Valid: true}, Title: "T", TranscriptText: "hello",
	})
	require.NoError(t, err)
	require.NoError(t, d.UpsertMeetingRecap("evt-recapped", "source", "{}", 0))
	// An ad-hoc recording (NULL event_id) must not poison the guard.
	_, err = d.InsertMeetingTranscript(MeetingTranscript{Title: "Ad-hoc", TranscriptText: "hello"})
	require.NoError(t, err)

	require.NoError(t, d.DeleteGoogleAccount(idA))

	for id, want := range map[string]bool{
		"evt-plain":    false,
		"evt-unlinked": false,
		"evt-recorded": true,
		"evt-recapped": true,
		"evt-b":        true,
	} {
		got, err := d.GetCalendarEventByID(id)
		require.NoError(t, err)
		assert.Equalf(t, want, got != nil, "event %s survives = %v", id, want)
	}

	var eventID sql.NullString
	require.NoError(t, d.QueryRow(`SELECT event_id FROM meeting_transcripts WHERE id = ?`, tid).Scan(&eventID))
	assert.Equal(t, "evt-recorded", eventID.String, "the recording keeps its event link")
	var recapEvent sql.NullString
	require.NoError(t, d.QueryRow(`SELECT event_id FROM meeting_recaps WHERE source_text = 'source'`).Scan(&recapEvent))
	assert.Equal(t, "evt-recapped", recapEvent.String, "the recap keeps its event link")

	type calRow struct {
		account  sql.NullInt64
		selected bool
	}
	rows, err := d.Query(`SELECT id, account_id, is_selected FROM calendar_calendars`)
	require.NoError(t, err)
	defer rows.Close()
	got := map[string]calRow{}
	for rows.Next() {
		var id string
		var r calRow
		require.NoError(t, rows.Scan(&id, &r.account, &r.selected))
		got[id] = r
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, map[string]calRow{
		"a-recorded": {account: sql.NullInt64{}, selected: false},
		"b-primary":  {account: sql.NullInt64{Int64: idB, Valid: true}, selected: true},
	}, got, "a-plain is deleted; a-recorded is kept but detached; B is untouched")

	_, err = d.GetGoogleAccount(idA)
	assert.Error(t, err, "the account row itself is deleted")
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
