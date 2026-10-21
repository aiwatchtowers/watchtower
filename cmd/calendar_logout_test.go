package cmd

import (
	"bytes"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func runCalendarCLI(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"calendar"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	return out.String(), err
}

func calendarEventExists(t *testing.T, database *db.DB, id string) bool {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM calendar_events WHERE id = ?`, id).Scan(&n))
	return n == 1
}

// calendar logout is the legacy alias for Google account #1: it must purge
// only that account's calendar data — never another Google account's, never
// CalDAV/ICS — which is exactly where the original unscoped wipe lived.
func TestCalendarLogout_PurgesOnlyTheDisconnectedAccount(t *testing.T) {
	database := writeActionsConfig(t)

	acctA, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", Label: "A", CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)
	acctB, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "b@example.com", Label: "B", CalendarEnabled: true})
	require.NoError(t, err)

	start := time.Now().UTC().Add(24 * time.Hour).Format(time.RFC3339)
	end := time.Now().UTC().Add(25 * time.Hour).Format(time.RFC3339)
	for _, c := range []struct {
		account int64
		id      string
	}{{acctA, "a-primary"}, {acctB, "b-primary"}, {0, "caldav:work"}} {
		require.NoError(t, database.UpsertCalendar(c.account, db.CalendarCalendar{ID: c.id, Name: c.id, IsSelected: true, SyncedAt: start}))
	}
	for id, cal := range map[string]string{"evt-a": "a-primary", "evt-b": "b-primary", "evt-caldav": "caldav:work"} {
		require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{ID: id, CalendarID: cal, Title: id, StartTime: start, EndTime: end}))
	}

	out, err := runCalendarCLI(t, "logout")
	require.NoError(t, err, out)

	assert.False(t, calendarEventExists(t, database, "evt-a"), "the disconnected account's event is purged")
	assert.True(t, calendarEventExists(t, database, "evt-b"), "another Google account's event survives")
	assert.True(t, calendarEventExists(t, database, "evt-caldav"), "a CalDAV event survives")

	acct, err := database.GetGoogleAccount(acctA)
	require.NoError(t, err)
	assert.False(t, acct.CalendarEnabled, "calendar is disconnected on account #1")
	assert.True(t, acct.GmailEnabled, "gmail stays connected")
}

func TestCalendarLogout_NoGoogleAccountIsANoop(t *testing.T) {
	database := writeActionsConfig(t)
	start := time.Now().UTC().Add(24 * time.Hour).Format(time.RFC3339)
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: "caldav:work", Name: "w", IsSelected: true, SyncedAt: start}))
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{ID: "evt-caldav", CalendarID: "caldav:work", Title: "x", StartTime: start, EndTime: start}))

	out, err := runCalendarCLI(t, "logout")
	require.NoError(t, err, out)
	assert.Contains(t, out, "No Google account connected")
	assert.True(t, calendarEventExists(t, database, "evt-caldav"))
}

// Review #601: disconnecting one Google service makes no authenticated call,
// so it must not stamp access_ok_at or clear revoked_at — that would cancel
// a scheduled purge without proof of access. A plain error (no revocation)
// is still cleared, so the Desktop's prompt goes away.
func TestGoogleDisconnect_NoAccessProof(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)
	const old = "2026-01-01T00:00:00Z"
	_, err = database.Exec(`UPDATE google_accounts SET status = 'revoked', error = 'gone', revoked_at = ?, access_ok_at = ? WHERE id = ?`, old, old, id)
	require.NoError(t, err)

	out, err := runCalendarCLI(t, "logout")
	require.NoError(t, err, out)

	var status, revokedAt, okAt string
	read := func() {
		require.NoError(t, database.QueryRow(`SELECT status, revoked_at, access_ok_at FROM google_accounts WHERE id = ?`, id).
			Scan(&status, &revokedAt, &okAt))
	}
	read()
	assert.Equal(t, "revoked", status, "a disconnect proves nothing about the grant")
	assert.Equal(t, old, revokedAt)
	assert.Equal(t, old, okAt)

	// An error without a revocation is cleared, clocks untouched.
	_, err = database.Exec(`UPDATE google_accounts SET status = 'error', error = 'scope', revoked_at = '', gmail_enabled = 1, calendar_enabled = 1 WHERE id = ?`, id)
	require.NoError(t, err)
	out, err = runCalendarCLI(t, "logout")
	require.NoError(t, err, out)
	read()
	assert.Equal(t, "ok", status)
	assert.Equal(t, old, okAt, "no access stamp without an authenticated call")
}
