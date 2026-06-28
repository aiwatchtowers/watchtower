package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func TestListTargets(t *testing.T) {
	database := seedDB(t)
	if _, err := database.CreateTarget(db.Target{
		Text:       "Ship MCP server",
		Intent:     "expose context",
		Level:      "week",
		Status:     "todo",
		Priority:   "high",
		Ownership:  "mine",
		SourceType: "manual",
	}); err != nil {
		t.Fatalf("seeding target: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_targets",
		Arguments: map[string]any{"status": "todo"},
	})
	if err != nil {
		t.Fatalf("call list_targets: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error result: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "Ship MCP server") {
		t.Fatalf("expected seeded target in output, got: %s", got)
	}
}

func TestListTargetsEmptyIsNotError(t *testing.T) {
	// Valid-but-degenerate input: a status with no matching rows must return an
	// empty array, not an error.
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_targets",
		Arguments: map[string]any{"status": "done"},
	})
	if err != nil {
		t.Fatalf("call list_targets: %v", err)
	}
	if res.IsError {
		t.Fatalf("empty result should not be an error: %s", textContent(t, res))
	}
	if got := strings.TrimSpace(textContent(t, res)); got != "[]" && got != "null" {
		t.Fatalf("expected empty array/null, got: %s", got)
	}
}

func TestGetTargetNotFound(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_target",
		Arguments: map[string]any{"id": 999},
	})
	if err != nil {
		t.Fatalf("call get_target: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected IsError for unknown id")
	}
}

func TestGetTarget(t *testing.T) {
	database := seedDB(t)
	id, err := database.CreateTarget(db.Target{
		Text:       "Ship MCP server",
		Intent:     "x",
		Level:      "week",
		Status:     "todo",
		Priority:   "high",
		Ownership:  "mine",
		SourceType: "manual",
	})
	if err != nil {
		t.Fatalf("seeding target: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_target",
		Arguments: map[string]any{"id": int(id)},
	})
	if err != nil {
		t.Fatalf("call get_target: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error result: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "Ship MCP server") {
		t.Fatalf("expected seeded target in output, got: %s", got)
	}
}
