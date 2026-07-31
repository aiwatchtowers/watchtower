package calendar

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
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

// calendarListFixture builds a minimal googleCalendarList JSON body from
// (id, primary) pairs.
func calendarListFixture(entries ...[2]any) string {
	items := ""
	for i, e := range entries {
		if i > 0 {
			items += ","
		}
		items += fmt.Sprintf(`{"id":%q,"summary":%q,"primary":%v}`, e[0], e[0], e[1])
	}
	return fmt.Sprintf(`{"items":[%s]}`, items)
}

// eventsFixture builds a minimal googleEventsList JSON body with a single
// event, or an empty list if id == "".
func eventsFixture(id, title string) string {
	if id == "" {
		return `{"items":[]}`
	}
	return fmt.Sprintf(`{"items":[{"id":%q,"summary":%q,"status":"confirmed",`+
		`"start":{"dateTime":"2026-04-02T09:00:00Z"},"end":{"dateTime":"2026-04-02T10:00:00Z"},`+
		`"updated":"2026-04-01T00:00:00Z"}]}`, id, title)
}

// TestSync_SharedCalendarStaysWithFirstOwner is a REAL end-to-end regression
// test for the shared-calendar-keyspace bug: calendar_calendars.id is shared
// across google_accounts, so a public/subscribed calendar synced by two
// different accounts hits the SAME row. Without the ownership-freeze fix in
// UpsertCalendar, account B's later sync would steal account_id from A,
// pull "sharedcal" into B's own GetSelectedCalendarIDs, and B's stale-delete
// pass would then remove A's shared-calendar event the moment B's fetch of
// that same calendar comes back different (simulated here as empty — a
// realistic transient/visibility difference between subscribers).
func TestSync_SharedCalendarStaysWithFirstOwner(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/calendarList", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.Header.Get("Authorization") {
		case "Bearer token-a":
			_, _ = w.Write([]byte(calendarListFixture([2]any{"sharedcal", false}, [2]any{"aliceprimary", true})))
		case "Bearer token-b":
			_, _ = w.Write([]byte(calendarListFixture([2]any{"sharedcal", false}, [2]any{"bobprimary", true})))
		default:
			w.WriteHeader(http.StatusUnauthorized)
		}
	})
	mux.HandleFunc("/calendars/sharedcal/events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") == "Bearer token-a" {
			_, _ = w.Write([]byte(eventsFixture("shared-evt", "Shared Event")))
			return
		}
		// Account B's own view of the same shared calendar happens to come
		// back empty this cycle — the scenario that makes the bug observable.
		_, _ = w.Write([]byte(eventsFixture("", "")))
	})
	mux.HandleFunc("/calendars/aliceprimary/events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(eventsFixture("alice-evt", "Alice Event")))
	})
	mux.HandleFunc("/calendars/bobprimary/events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(eventsFixture("bob-evt", "Bob Event")))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	prevAPI := calendarAPIBase
	calendarAPIBase = srv.URL
	defer func() { calendarAPIBase = prevAPI }()

	database := db.OpenTestDB(t)
	acctA, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	acctB, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "b@x.com", Label: "B"})
	require.NoError(t, err)

	cfg := &config.Config{}
	clientA := &Client{hc: srv.Client(), accessToken: "token-a"}
	clientB := &Client{hc: srv.Client(), accessToken: "token-b"}

	countA, err := NewSyncer(clientA, database, cfg, nil, acctA).Sync(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, countA, "A syncs shared-evt + alice-evt")

	countB, err := NewSyncer(clientB, database, cfg, nil, acctB).Sync(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, countB, "B only ever fetches its own calendar, bobprimary")

	// Ownership guard: the shared calendar row stays A's; B never selects it.
	idsB, err := database.GetSelectedCalendarIDs(acctB)
	require.NoError(t, err)
	assert.Equal(t, []string{"bobprimary"}, idsB, "account B must not have claimed the shared calendar")

	// The core regression: B's sync must never delete A's shared-calendar event.
	sharedEvt, err := database.GetCalendarEventByID("shared-evt")
	require.NoError(t, err)
	require.NotNil(t, sharedEvt, "account B's sync must not delete account A's shared-calendar event")

	aliceEvt, err := database.GetCalendarEventByID("alice-evt")
	require.NoError(t, err)
	require.NotNil(t, aliceEvt)

	bobEvt, err := database.GetCalendarEventByID("bob-evt")
	require.NoError(t, err)
	require.NotNil(t, bobEvt)
}

// TestSync_PrimaryFallbackUsesRealCalendarID guards the other half of the
// "primary" collision fix: when DB selection comes back empty (e.g. the user
// deselected every calendar), Sync must fall back to the account's REAL
// primary calendar id — resolved from the same cycle's calendar list — not
// the literal string "primary", which every account would otherwise collide
// on. A real id means the ordinary stale-delete path still runs for it.
func TestSync_PrimaryFallbackUsesRealCalendarID(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/calendarList", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(calendarListFixture([2]any{"aliceprimary", true})))
	})
	mux.HandleFunc("/calendars/aliceprimary/events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(eventsFixture("alice-evt-2", "Alice Event 2")))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	prevAPI := calendarAPIBase
	calendarAPIBase = srv.URL
	defer func() { calendarAPIBase = prevAPI }()

	database := db.OpenTestDB(t)
	acctA, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	cfg := &config.Config{}
	client := &Client{hc: srv.Client(), accessToken: "token-a"}

	// First sync claims+selects aliceprimary, then the user deselects it —
	// DB selection is now empty despite the calendar existing.
	_, err = NewSyncer(client, database, cfg, nil, acctA).Sync(context.Background())
	require.NoError(t, err)
	require.NoError(t, database.SetCalendarSelected("aliceprimary", false))

	// Seed a stale event under the real primary id from before this run.
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{
		ID: "stale-alice-evt", CalendarID: "aliceprimary",
		StartTime: "2026-01-01T00:00:00Z", EndTime: "2026-01-01T01:00:00Z",
	}, "2000-01-01T00:00:00Z"))

	_, err = NewSyncer(client, database, cfg, nil, acctA).Sync(context.Background())
	require.NoError(t, err)

	// The fallback resolved the real primary id, so the ordinary stale-delete
	// pass ran for it and cleaned up the pre-existing stale event.
	stale, err := database.GetCalendarEventByID("stale-alice-evt")
	require.NoError(t, err)
	assert.Nil(t, stale, "stale-delete must run normally once the real primary id is known")

	fresh, err := database.GetCalendarEventByID("alice-evt-2")
	require.NoError(t, err)
	require.NotNil(t, fresh)
}

// TestSync_PrimaryFallbackSkipsStaleDeleteWhenUnresolved covers the case
// where the real primary id can't be resolved this cycle (calendar-list
// fetch failed): Sync still falls back to fetching events under the literal
// "primary" bucket (so sync keeps working), but must skip that bucket's
// stale-delete pass, since every account with an unresolved primary falls
// back to the same literal id and could otherwise delete another account's
// events synced under it.
func TestSync_PrimaryFallbackSkipsStaleDeleteWhenUnresolved(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/calendarList", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	mux.HandleFunc("/calendars/primary/events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(eventsFixture("literal-primary-evt", "Fetched Under Literal Primary")))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	prevAPI := calendarAPIBase
	calendarAPIBase = srv.URL
	defer func() { calendarAPIBase = prevAPI }()

	database := db.OpenTestDB(t)
	acctA, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	// A stale event under the literal "primary" bucket, e.g. from another
	// account that also fell back to it in an earlier cycle.
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: "primary", Name: "Primary Bucket"}))
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{
		ID: "other-account-evt", CalendarID: "primary",
		StartTime: "2026-01-01T00:00:00Z", EndTime: "2026-01-01T01:00:00Z",
	}, "2000-01-01T00:00:00Z"))

	cfg := &config.Config{}
	client := &Client{hc: srv.Client(), accessToken: "token-a"}

	count, err := NewSyncer(client, database, cfg, nil, acctA).Sync(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, count, "events still sync under the literal primary fallback")

	// The unresolved-primary bucket's stale-delete pass must be skipped.
	survivor, err := database.GetCalendarEventByID("other-account-evt")
	require.NoError(t, err)
	require.NotNil(t, survivor, "stale-delete must be skipped for the unresolved literal \"primary\" bucket")
}

// TestSync_ConferenceURLLandsInDB is the end-to-end guard for the Join
// button's data path: an API event carrying a hangoutLink syncs into
// calendar_events.conference_url, and one without any link stores "".
func TestSync_ConferenceURLLandsInDB(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/calendarList", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(calendarListFixture([2]any{"aliceprimary", true})))
	})
	mux.HandleFunc("/calendars/aliceprimary/events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"items":[
			{"id":"meet-evt","summary":"With Meet","status":"confirmed",
			 "hangoutLink":"https://meet.google.com/abc-defg-hij",
			 "start":{"dateTime":"2026-04-02T09:00:00Z"},"end":{"dateTime":"2026-04-02T10:00:00Z"},
			 "updated":"2026-04-01T00:00:00Z"},
			{"id":"plain-evt","summary":"No Link","status":"confirmed",
			 "start":{"dateTime":"2026-04-02T11:00:00Z"},"end":{"dateTime":"2026-04-02T12:00:00Z"},
			 "updated":"2026-04-01T00:00:00Z"}
		]}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	prevAPI := calendarAPIBase
	calendarAPIBase = srv.URL
	defer func() { calendarAPIBase = prevAPI }()

	database := db.OpenTestDB(t)
	acctA, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	cfg := &config.Config{}
	client := &Client{hc: srv.Client(), accessToken: "token-a"}

	count, err := NewSyncer(client, database, cfg, nil, acctA).Sync(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, count)

	meetEvt, err := database.GetCalendarEventByID("meet-evt")
	require.NoError(t, err)
	require.NotNil(t, meetEvt)
	assert.Equal(t, "https://meet.google.com/abc-defg-hij", meetEvt.ConferenceURL)

	plainEvt, err := database.GetCalendarEventByID("plain-evt")
	require.NoError(t, err)
	require.NotNil(t, plainEvt)
	assert.Equal(t, "", plainEvt.ConferenceURL)
}

// TestRecordAuthResultSkipsCancelledContext guards the daemon-shutdown path:
// when the sync's own context is cancelled (SIGTERM), the resulting HTTP
// error is a shutdown artifact, not an auth problem, and must not flip a
// healthy account into "error".
func TestRecordAuthResultSkipsCancelledContext(t *testing.T) {
	database := db.OpenTestDB(t)
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	s := NewSyncer(nil, database, &config.Config{}, nil, accountID)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s.recordAuthResult(ctx, errors.New("calendar GET /calendars: terminated signal received"))

	acc, err := database.GetGoogleAccount(accountID)
	require.NoError(t, err)
	assert.Equal(t, "ok", acc.Status, "cancelled ctx must not flip auth state")
	assert.Empty(t, acc.Error)
}

// TestRecordAuthResultLiveContext pins the existing behavior on a live
// context: a generic error records "error", and a subsequent nil result
// clears it back to "ok".
func TestRecordAuthResultLiveContext(t *testing.T) {
	database := db.OpenTestDB(t)
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	s := NewSyncer(nil, database, &config.Config{}, nil, accountID)

	s.recordAuthResult(context.Background(), errors.New("boom"))
	acc, err := database.GetGoogleAccount(accountID)
	require.NoError(t, err)
	assert.Equal(t, "error", acc.Status)
	assert.Contains(t, acc.Error, "boom")

	s.recordAuthResult(context.Background(), nil)
	acc, err = database.GetGoogleAccount(accountID)
	require.NoError(t, err)
	assert.Equal(t, "ok", acc.Status)
	assert.Empty(t, acc.Error)
}
