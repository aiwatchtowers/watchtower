package mcp

import (
	"context"
	"strings"
	"testing"

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
		Arguments: map[string]any{"user_id": "U_NOBODY"},
	})
	if err != nil {
		t.Fatalf("call get_person: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected error for unknown user, got: %s", textContent(t, res))
	}
}
