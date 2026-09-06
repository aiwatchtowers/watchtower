package tools

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func peopleRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	for _, tool := range []*Tool{NewListPeople(), NewGetPerson(), NewListTracks(), NewGetTrack(), NewListUpcomingEvents()} {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

func seedPersonCard(t *testing.T, d *db.DB, id, name, realName, summary string) {
	t.Helper()
	require.NoError(t, d.UpsertUser(db.User{ID: id, Name: name, RealName: realName}))
	_, err := d.UpsertPeopleCard(db.PeopleCard{UserID: id, Summary: summary, Status: "active", PeriodFrom: 1, PeriodTo: 2})
	require.NoError(t, err)
}

func TestGetPerson_NotFound(t *testing.T) {
	_, err := peopleRegistry(t, openDB(t)).CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"U_NOBODY"}`))
	require.Error(t, err)
}

// An LLM client rarely knows Slack ids — get_person resolves by partial name.
func TestGetPerson_ByName(t *testing.T) {
	d := openDB(t)
	seedPersonCard(t, d, "U100", "alice", "Alice Smith", "drives launches")

	got := callReadString(t, peopleRegistry(t, d), "get_person", `{"query":"Alice"}`)
	assert.Contains(t, got, "drives launches")
}

// Several name matches → an ambiguity error listing the candidate ids.
func TestGetPerson_AmbiguousName(t *testing.T) {
	d := openDB(t)
	seedPersonCard(t, d, "U101", "alice.a", "Alice Anderson", "card U101")
	seedPersonCard(t, d, "U102", "alice.b", "Alice Brown", "card U102")

	_, err := peopleRegistry(t, d).CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"alice"}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "U101")
	assert.Contains(t, err.Error(), "U102")
}

func TestListTracks_FiltersAndRejectsBadEnum(t *testing.T) {
	d := openDB(t)
	_, err := d.UpsertTrack(db.Track{Text: "Launch readiness", Category: "discussion", Priority: "high", Ownership: "mine"})
	require.NoError(t, err)

	got := callReadString(t, peopleRegistry(t, d), "list_tracks", `{"priority":"high"}`)
	assert.Contains(t, got, "Launch readiness")

	_, err = peopleRegistry(t, d).CallRead(context.Background(), "list_tracks", json.RawMessage(`{"priority":"urgent"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "high|medium|low")
}

func TestGetTrack_NotFound(t *testing.T) {
	_, err := peopleRegistry(t, openDB(t)).CallRead(context.Background(), "get_track", json.RawMessage(`{"id":999}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no track with id 999")
	assert.NotContains(t, err.Error(), "sql: no rows")
}

func TestListPeople_ReturnsCards(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U1", Name: "alice", RealName: "Alice Smith"}))
	_, err := d.UpsertPeopleCard(db.PeopleCard{UserID: "U1", Summary: "works on launch", Status: "active", PeriodFrom: 1, PeriodTo: 2})
	require.NoError(t, err)

	got := callReadString(t, peopleRegistry(t, d), "list_people", `{}`)
	assert.Contains(t, got, "works on launch")
}

func TestListPeople_EmptyIsArray(t *testing.T) {
	got := callReadString(t, peopleRegistry(t, openDB(t)), "list_people", `{}`)
	assert.Equal(t, "[]", got)
}

// The 48h window includes an event 1h out and excludes one 100h out.
func TestListUpcomingEvents_Window(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertCalendar(0, db.CalendarCalendar{ID: "cal1", Name: "Primary"}))
	now := time.Now().UTC()
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID: "ev-in", CalendarID: "cal1", Title: "Standup soon",
		StartTime: now.Add(time.Hour).Format(time.RFC3339), EndTime: now.Add(2 * time.Hour).Format(time.RFC3339),
	}))
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID: "ev-out", CalendarID: "cal1", Title: "Far future offsite",
		StartTime: now.Add(100 * time.Hour).Format(time.RFC3339), EndTime: now.Add(101 * time.Hour).Format(time.RFC3339),
	}))

	got := callReadString(t, peopleRegistry(t, d), "list_upcoming_events", `{"hours":48}`)
	assert.Contains(t, got, "Standup soon")
	assert.NotContains(t, got, "Far future offsite", "48h window must exclude the +100h event")
}
