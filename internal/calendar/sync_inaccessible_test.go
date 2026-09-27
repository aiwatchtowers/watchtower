package calendar

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// inaccessibleCalendarSetup serves a calendar list of listed ids (primary
// first) and answers events.list for "gonecal" with goneStatus, and every
// other calendar with one event. It returns an account whose selection
// already includes "gonecal" plus a pre-existing event under it.
func inaccessibleCalendarSetup(t *testing.T, goneStatus int, listed ...[2]any) (*db.DB, int64, *Client) {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/calendarList", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(calendarListFixture(listed...)))
	})
	mux.HandleFunc("/calendars/gonecal/events", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(goneStatus)
		_, _ = w.Write([]byte(`{"error":{"code":404,"message":"Not Found"}}`))
	})
	mux.HandleFunc("/calendars/aliceprimary/events", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(eventsFixture("alice-evt", "Alice Event")))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	prevAPI := calendarAPIBase
	calendarAPIBase = srv.URL
	t.Cleanup(func() { calendarAPIBase = prevAPI })

	database := db.OpenTestDB(t)
	acct, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", Label: "A"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertCalendar(acct, db.CalendarCalendar{
		ID: "gonecal", Name: "Gone", IsSelected: true, SyncedAt: "2000-01-01T00:00:00Z",
	}))
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{
		ID: "gone-evt", CalendarID: "gonecal",
		StartTime: "2026-01-01T00:00:00Z", EndTime: "2026-01-01T01:00:00Z",
	}, "2000-01-01T00:00:00Z"))
	return database, acct, &Client{hc: srv.Client(), accessToken: "token-a"}
}

func assertOtherCalendarsSynced(t *testing.T, database *db.DB, acct int64, err error) {
	t.Helper()
	require.NoError(t, err, "one inaccessible calendar must not fail the account's sync")
	evt, err := database.GetCalendarEventByID("alice-evt")
	require.NoError(t, err)
	require.NotNil(t, evt, "the account's other calendars must still sync")
	gone, err := database.GetCalendarEventByID("gone-evt")
	require.NoError(t, err)
	assert.NotNil(t, gone, "an unfetched calendar's events must not be stale-deleted")
	acctRow, err := database.GetGoogleAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "ok", acctRow.Status)
}

// TestSync_InaccessibleSelectedCalendarDoesNotStopTheAccount: a selected
// calendar still in the calendar list whose events.list now 404s/410s
// (unshared, deleted between the two calls) is skipped for this cycle — the
// other calendars still sync, its events are left alone, the account stays ok.
func TestSync_InaccessibleSelectedCalendarDoesNotStopTheAccount(t *testing.T) {
	for _, status := range []int{http.StatusNotFound, http.StatusGone} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			database, acct, client := inaccessibleCalendarSetup(t, status,
				[2]any{"aliceprimary", true}, [2]any{"gonecal", false})
			_, err := NewSyncer(client, database, &config.Config{}, nil, acct).Sync(context.Background())
			assertOtherCalendarsSynced(t, database, acct, err)
		})
	}
}

// TestSync_UnlistedCalendarIsDeselected: a calendar that has dropped out of
// the account's calendar list is deselected on a successful list fetch, so
// GetSelectedCalendarIDs stops returning the dead id and the account
// recovers instead of retrying it every cycle.
func TestSync_UnlistedCalendarIsDeselected(t *testing.T) {
	database, acct, client := inaccessibleCalendarSetup(t, http.StatusNotFound, [2]any{"aliceprimary", true})
	_, err := NewSyncer(client, database, &config.Config{}, nil, acct).Sync(context.Background())
	assertOtherCalendarsSynced(t, database, acct, err)

	ids, err := database.GetSelectedCalendarIDs(acct)
	require.NoError(t, err)
	assert.Equal(t, []string{"aliceprimary"}, ids, "the unlisted calendar must be deselected")
}

// TestClient_FetchEvents_OtherErrorsStillFail pins the other side of the
// 404/410 tolerance: a 403 (rate limit, insufficient scope) or 5xx is not a
// gone calendar and must still fail the fetch, so recordAuthResult sees it.
func TestClient_FetchEvents_OtherErrorsStillFail(t *testing.T) {
	for _, status := range []int{http.StatusForbidden, http.StatusInternalServerError} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(status)
			}))
			t.Cleanup(srv.Close)
			prev := calendarAPIBase
			calendarAPIBase = srv.URL
			t.Cleanup(func() { calendarAPIBase = prev })

			c := &Client{hc: srv.Client(), accessToken: "at"}
			_, gone, err := c.FetchEvents(context.Background(), []string{"work"}, mustTime("2026-04-02T00:00:00Z"), mustTime("2026-04-03T00:00:00Z"))
			require.Error(t, err)
			assert.Empty(t, gone)
		})
	}
}
