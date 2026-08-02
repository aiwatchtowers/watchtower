package mcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func TestListTracks(t *testing.T) {
	database := seedDB(t)
	if _, err := database.UpsertTrack(db.Track{
		Text:      "Launch readiness",
		Context:   "team is preparing the launch",
		Category:  "discussion",
		Ownership: "mine",
		Priority:  "medium",
	}); err != nil {
		t.Fatalf("seeding track: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_tracks",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call list_tracks: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "Launch readiness") {
		t.Fatalf("expected seeded track, got: %s", got)
	}
}

func TestGetTrack(t *testing.T) {
	database := seedDB(t)
	id, err := database.UpsertTrack(db.Track{
		Text:      "Deploy pipeline",
		Ownership: "mine",
		Priority:  "high",
	})
	if err != nil {
		t.Fatalf("seeding track: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_track",
		Arguments: map[string]any{"id": int(id)},
	})
	if err != nil {
		t.Fatalf("call get_track: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "Deploy pipeline") {
		t.Fatalf("expected track text, got: %s", got)
	}
}

func TestGetTrackNotFound(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_track",
		Arguments: map[string]any{"id": 9999},
	})
	if err != nil {
		t.Fatalf("call get_track: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected error for missing track, got: %s", textContent(t, res))
	}
	// F1/F2: friendly message, not the leaked raw SQL sentinel.
	msg := textContent(t, res)
	if !strings.Contains(msg, "no track with id 9999") {
		t.Fatalf("expected friendly not-found message, got: %s", msg)
	}
	if strings.Contains(msg, "sql: no rows") {
		t.Fatalf("not-found leaked the raw SQL sentinel: %s", msg)
	}
}

func TestListUpcomingEventsEmpty(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_upcoming_events",
		Arguments: map[string]any{"hours": 48},
	})
	if err != nil {
		t.Fatalf("call list_upcoming_events: %v", err)
	}
	if res.IsError {
		t.Fatalf("empty calendar should not be an error: %s", textContent(t, res))
	}
}

// TestListUpcomingEventsWindow exercises the time-window logic: an event inside
// the look-ahead window appears; one beyond it is excluded.
func TestListUpcomingEventsWindow(t *testing.T) {
	database := seedDB(t)
	if err := database.UpsertCalendar(0, db.CalendarCalendar{ID: "cal1", Name: "Primary"}); err != nil {
		t.Fatalf("seeding calendar: %v", err)
	}
	now := time.Now().UTC()
	inWindow := db.CalendarEvent{
		ID: "ev-in", CalendarID: "cal1", Title: "Standup soon",
		StartTime: now.Add(1 * time.Hour).Format(time.RFC3339),
		EndTime:   now.Add(2 * time.Hour).Format(time.RFC3339),
	}
	outOfWindow := db.CalendarEvent{
		ID: "ev-out", CalendarID: "cal1", Title: "Far future offsite",
		StartTime: now.Add(100 * time.Hour).Format(time.RFC3339),
		EndTime:   now.Add(101 * time.Hour).Format(time.RFC3339),
	}
	if err := database.UpsertCalendarEvent(inWindow); err != nil {
		t.Fatalf("seeding in-window event: %v", err)
	}
	if err := database.UpsertCalendarEvent(outOfWindow); err != nil {
		t.Fatalf("seeding out-of-window event: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_upcoming_events",
		Arguments: map[string]any{"hours": 48},
	})
	if err != nil {
		t.Fatalf("call list_upcoming_events: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "Standup soon") {
		t.Fatalf("expected in-window event, got: %s", got)
	}
	if strings.Contains(got, "Far future offsite") {
		t.Fatalf("48h window did not exclude the +100h event, got: %s", got)
	}
}

func TestListPeople(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_people",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call list_people: %v", err)
	}
	if res.IsError {
		t.Fatalf("empty people should not be an error: %s", textContent(t, res))
	}
}

func TestGetPersonNotFound(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_person",
		Arguments: map[string]any{"query": "U_NOBODY"},
	})
	if err != nil {
		t.Fatalf("call get_person: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected error for unknown user, got: %s", textContent(t, res))
	}
}

// TestGetPersonByName: an LLM client rarely knows Slack user ids — get_person
// must also resolve a person by (partial, case-insensitive) name.
func TestGetPersonByName(t *testing.T) {
	database := seedDB(t)
	if err := database.UpsertUser(db.User{ID: "U100", Name: "alice", RealName: "Alice Smith"}); err != nil {
		t.Fatalf("seeding user: %v", err)
	}
	if _, err := database.UpsertPeopleCard(db.PeopleCard{
		UserID: "U100", Summary: "drives launches", Status: "active", PeriodFrom: 1, PeriodTo: 2,
	}); err != nil {
		t.Fatalf("seeding people card: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_person",
		Arguments: map[string]any{"query": "Alice"},
	})
	if err != nil {
		t.Fatalf("call get_person: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "drives launches") {
		t.Fatalf("expected the card for alice, got: %s", got)
	}
}

// TestGetPersonAmbiguousName: several people-carded users matching the name →
// a clear error listing the candidate ids, not an arbitrary pick.
func TestGetPersonAmbiguousName(t *testing.T) {
	database := seedDB(t)
	for _, u := range []db.User{
		{ID: "U101", Name: "alice.a", RealName: "Alice Anderson"},
		{ID: "U102", Name: "alice.b", RealName: "Alice Brown"},
	} {
		if err := database.UpsertUser(u); err != nil {
			t.Fatalf("seeding user %s: %v", u.ID, err)
		}
		if _, err := database.UpsertPeopleCard(db.PeopleCard{
			UserID: u.ID, Summary: "card " + u.ID, Status: "active", PeriodFrom: 1, PeriodTo: 2,
		}); err != nil {
			t.Fatalf("seeding card %s: %v", u.ID, err)
		}
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_person",
		Arguments: map[string]any{"query": "alice"},
	})
	if err != nil {
		t.Fatalf("call get_person: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected ambiguity error, got: %s", textContent(t, res))
	}
	msg := textContent(t, res)
	if !strings.Contains(msg, "U101") || !strings.Contains(msg, "U102") {
		t.Fatalf("ambiguity error should list candidate ids, got: %s", msg)
	}
}

// TestListPeopleLimit: list_people accepts a limit like every other list_ tool.
func TestListPeopleLimit(t *testing.T) {
	database := seedDB(t)
	for _, id := range []string{"U201", "U202"} {
		if _, err := database.UpsertPeopleCard(db.PeopleCard{
			UserID: id, Summary: "s", Status: "active", PeriodFrom: 1, PeriodTo: 2,
		}); err != nil {
			t.Fatalf("seeding card %s: %v", id, err)
		}
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_people",
		Arguments: map[string]any{"limit": 1},
	})
	if err != nil {
		t.Fatalf("call list_people: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	var items []map[string]any
	if err := json.Unmarshal([]byte(textContent(t, res)), &items); err != nil {
		t.Fatalf("result is not a JSON array: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("limit=1 should return 1 card, got %d", len(items))
	}
}

// TestListUpcomingEventsLimit: list_upcoming_events accepts a limit too.
func TestListUpcomingEventsLimit(t *testing.T) {
	database := seedDB(t)
	if err := database.UpsertCalendar(0, db.CalendarCalendar{ID: "cal1", Name: "Primary"}); err != nil {
		t.Fatalf("seeding calendar: %v", err)
	}
	now := time.Now().UTC()
	for i, id := range []string{"ev-1", "ev-2"} {
		ev := db.CalendarEvent{
			ID: id, CalendarID: "cal1", Title: "Event " + id,
			StartTime: now.Add(time.Duration(i+1) * time.Hour).Format(time.RFC3339),
			EndTime:   now.Add(time.Duration(i+2) * time.Hour).Format(time.RFC3339),
		}
		if err := database.UpsertCalendarEvent(ev); err != nil {
			t.Fatalf("seeding event %s: %v", id, err)
		}
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_upcoming_events",
		Arguments: map[string]any{"limit": 1},
	})
	if err != nil {
		t.Fatalf("call list_upcoming_events: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	var items []map[string]any
	if err := json.Unmarshal([]byte(textContent(t, res)), &items); err != nil {
		t.Fatalf("result is not a JSON array: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("limit=1 should return 1 event, got %d", len(items))
	}
}

func TestListTracksInvalidPriority(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_tracks",
		Arguments: map[string]any{"priority": "urgent"},
	})
	if err != nil {
		t.Fatalf("call list_tracks: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected validation error for priority=urgent, got: %s", textContent(t, res))
	}
	if msg := textContent(t, res); !strings.Contains(msg, "urgent") || !strings.Contains(msg, "high|medium|low") {
		t.Fatalf("error should name the bad value and allowed set, got: %s", msg)
	}
}
