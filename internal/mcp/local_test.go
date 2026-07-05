package mcp

import (
	"context"
	"strings"
	"testing"
)

// newLocalSession mirrors production wiring (cmd/tools.go): read-only DB,
// server + in-process client via ConnectLocal.
func newLocalSession(t *testing.T) *LocalSession {
	t.Helper()
	database := seedDB(t)
	if err := database.SetReadOnly(); err != nil {
		t.Fatalf("setting read-only: %v", err)
	}
	ls, err := NewServer(database).ConnectLocal(context.Background())
	if err != nil {
		t.Fatalf("ConnectLocal: %v", err)
	}
	t.Cleanup(func() { _ = ls.Close() })
	return ls
}

func TestLocalSession_ToolsListsRegisteredToolsWithArgs(t *testing.T) {
	ls := newLocalSession(t)

	tools, err := ls.Tools(context.Background())
	if err != nil {
		t.Fatalf("Tools: %v", err)
	}
	byName := map[string]ToolInfo{}
	for _, ti := range tools {
		byName[ti.Name] = ti
	}
	for _, want := range []string{
		"list_targets", "get_target", "get_today_briefing", "list_digests",
		"get_digest", "list_people", "get_person", "list_tracks", "get_track",
		"list_upcoming_events", "list_jira_issues", "get_jira_issue",
	} {
		if _, ok := byName[want]; !ok {
			t.Errorf("tool %q missing from Tools()", want)
		}
	}

	lt := byName["list_targets"]
	if lt.Description == "" {
		t.Error("list_targets has no description")
	}
	args := map[string]ToolArg{}
	for _, a := range lt.Args {
		args[a.Name] = a
	}
	if a, ok := args["status"]; !ok || a.Type != "string" || a.Description == "" {
		t.Errorf("list_targets arg status not extracted from schema: %+v", args["status"])
	}
	if a, ok := args["limit"]; !ok || a.Type != "integer" {
		t.Errorf("list_targets arg limit should be integer: %+v", args["limit"])
	}

	// Sorted by name for stable CLI output.
	for i := 1; i < len(tools); i++ {
		if tools[i-1].Name > tools[i].Name {
			t.Fatalf("tools not sorted: %q before %q", tools[i-1].Name, tools[i].Name)
		}
	}
}

func TestLocalSession_CallReturnsJSONArray(t *testing.T) {
	ls := newLocalSession(t)

	text, isErr, err := ls.Call(context.Background(), "list_targets", nil)
	if err != nil {
		t.Fatalf("Call: %v", err)
	}
	if isErr {
		t.Fatalf("unexpected tool error: %s", text)
	}
	if strings.TrimSpace(text) != "[]" {
		t.Fatalf("empty DB should list [], got %q", text)
	}
}

func TestLocalSession_CallSurfacesToolError(t *testing.T) {
	ls := newLocalSession(t)

	text, isErr, err := ls.Call(context.Background(), "list_targets",
		map[string]any{"status": "bogus"})
	if err != nil {
		t.Fatalf("Call: %v", err)
	}
	if !isErr {
		t.Fatal("invalid enum must produce a tool-level error")
	}
	if !strings.Contains(text, "invalid status") {
		t.Fatalf("tool error text should explain the invalid enum, got %q", text)
	}
}

func TestLocalSession_CallUnknownToolErrors(t *testing.T) {
	ls := newLocalSession(t)

	if _, _, err := ls.Call(context.Background(), "no_such_tool", nil); err == nil {
		t.Fatal("expected protocol error for unknown tool")
	}
}
