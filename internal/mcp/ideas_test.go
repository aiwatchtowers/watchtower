package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// seedIdea creates an idea (plus, when quote is non-empty, one mention) and
// returns its id.
func seedIdea(t *testing.T, database *db.DB, idea db.Idea, quote string) int64 {
	t.Helper()
	tx, err := database.Begin()
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	id, err := database.CreateIdeaTx(tx, idea)
	if err != nil {
		t.Fatalf("CreateIdeaTx: %v", err)
	}
	if quote != "" {
		if err := database.InsertIdeaMentionTx(tx, db.IdeaMention{
			IdeaID: id, Source: "slack", Ref: "C1:123.456", Quote: quote, Author: "U1",
			SaidAt: "2026-06-01T00:00:00Z",
		}); err != nil {
			t.Fatalf("InsertIdeaMentionTx: %v", err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}
	return id
}

func TestListIdeas(t *testing.T) {
	database := seedDB(t)
	seedIdea(t, database, db.Idea{Kind: "idea", Title: "Ship dark mode", Status: "proposed", Source: "mined"}, "")
	seedIdea(t, database, db.Idea{Kind: "decision", Title: "Use SQLite", Status: "active", Source: "mined"}, "")
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_ideas",
		Arguments: map[string]any{"kind": "idea"},
	})
	if err != nil {
		t.Fatalf("call list_ideas: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "Ship dark mode") {
		t.Fatalf("expected seeded idea, got: %s", got)
	}
	if strings.Contains(got, "Use SQLite") {
		t.Fatalf("expected kind filter to exclude the decision, got: %s", got)
	}
}

func TestListIdeasInvalidKind(t *testing.T) {
	cs := newTestSession(t, seedDB(t))

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_ideas",
		Arguments: map[string]any{"kind": "bogus"},
	})
	if err != nil {
		t.Fatalf("call list_ideas: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected IsError for an invalid kind")
	}
}

func TestGetIdea(t *testing.T) {
	database := seedDB(t)
	id := seedIdea(t, database, db.Idea{Kind: "idea", Title: "Ship dark mode", Status: "proposed", Source: "mined"}, "please add dark mode")
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_idea",
		Arguments: map[string]any{"id": id},
	})
	if err != nil {
		t.Fatalf("call get_idea: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "Ship dark mode") {
		t.Fatalf("expected idea title, got: %s", got)
	}
	if !strings.Contains(got, "please add dark mode") {
		t.Fatalf("expected mention quote in response, got: %s", got)
	}
}

func TestGetIdeaNotFound(t *testing.T) {
	cs := newTestSession(t, seedDB(t))

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_idea",
		Arguments: map[string]any{"id": 999999},
	})
	if err != nil {
		t.Fatalf("call get_idea: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected IsError for a missing idea")
	}
}
