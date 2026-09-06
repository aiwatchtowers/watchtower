package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

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
