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
	// A non-matching row proves the status filter actually EXCLUDES rather than
	// being silently ignored.
	if _, err := database.CreateTarget(db.Target{
		Text:       "Unrelated in-progress item",
		Intent:     "x",
		Level:      "week",
		Status:     "in_progress",
		Priority:   "low",
		Ownership:  "mine",
		SourceType: "manual",
	}); err != nil {
		t.Fatalf("seeding non-matching target: %v", err)
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
	got := textContent(t, res)
	if !strings.Contains(got, "Ship MCP server") {
		t.Fatalf("expected matching target in output, got: %s", got)
	}
	if strings.Contains(got, "Unrelated in-progress item") {
		t.Fatalf("status filter did not exclude the non-matching target, got: %s", got)
	}
}

// TestListTargetsByDoneStatus guards C1: filtering by status=done/dismissed must
// return those targets. GetTargets excludes done/dismissed unless IncludeDone is
// set, so the handler has to opt in — without it this returns [].
func TestListTargetsByDoneStatus(t *testing.T) {
	database := seedDB(t)
	if _, err := database.CreateTarget(db.Target{
		Text:       "Finished work",
		Intent:     "x",
		Level:      "week",
		Status:     "done",
		Priority:   "medium",
		Ownership:  "mine",
		SourceType: "manual",
	}); err != nil {
		t.Fatalf("seeding done target: %v", err)
	}
	for _, status := range []string{"done", "dismissed"} {
		if _, err := database.CreateTarget(db.Target{
			Text:       "dismissed-" + status,
			Intent:     "x",
			Level:      "week",
			Status:     "dismissed",
			Priority:   "low",
			Ownership:  "mine",
			SourceType: "manual",
		}); err != nil {
			t.Fatalf("seeding dismissed target: %v", err)
		}
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_targets",
		Arguments: map[string]any{"status": "done"},
	})
	if err != nil {
		t.Fatalf("call list_targets: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error result: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "Finished work") {
		t.Fatalf("status=done returned no done targets (C1 regression), got: %s", got)
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
	// F1/F2: the not-found result must be the friendly message, not the leaked
	// raw `sql: no rows in result set` sentinel.
	msg := textContent(t, res)
	if !strings.Contains(msg, "no target with id 999") {
		t.Fatalf("expected friendly not-found message, got: %s", msg)
	}
	if strings.Contains(msg, "sql: no rows") {
		t.Fatalf("not-found leaked the raw SQL sentinel: %s", msg)
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

// TestListTargetsInvalidEnumValues: a bogus filter value must produce a clear
// validation error listing the allowed values — not silently return [] (which
// an LLM client would read as "no targets").
func TestListTargetsInvalidEnumValues(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	cases := []struct{ field, value, wantAllowed string }{
		{"status", "in-progress", "todo|in_progress|blocked|done|dismissed|snoozed"},
		{"priority", "urgent", "high|medium|low"},
		{"level", "year", "quarter|month|week|day|custom"},
		{"ownership", "theirs", "mine|delegated|watching"},
	}
	for _, c := range cases {
		res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
			Name:      "list_targets",
			Arguments: map[string]any{c.field: c.value},
		})
		if err != nil {
			t.Fatalf("call list_targets (%s=%s): %v", c.field, c.value, err)
		}
		if !res.IsError {
			t.Errorf("%s=%q: expected validation error, got: %s", c.field, c.value, textContent(t, res))
			continue
		}
		msg := textContent(t, res)
		if !strings.Contains(msg, c.value) || !strings.Contains(msg, c.wantAllowed) {
			t.Errorf("%s=%q: error should name the bad value and allowed set, got: %s", c.field, c.value, msg)
		}
	}
}
