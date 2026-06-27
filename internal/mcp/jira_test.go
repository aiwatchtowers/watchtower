package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func TestListJiraIssues(t *testing.T) {
	database := seedDB(t)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		Key: "ABC-1", ID: "ABC-1", ProjectKey: "ABC", Summary: "fix the thing",
		Status: "To Do", StatusCategory: "To Do",
		CreatedAt: "2026-06-01T00:00:00Z", UpdatedAt: "2026-06-02T00:00:00Z",
		SyncedAt: "2026-06-02T00:00:00Z",
	}); err != nil {
		t.Fatalf("seeding jira issue: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_jira_issues",
		Arguments: map[string]any{"project": "ABC"},
	})
	if err != nil {
		t.Fatalf("call list_jira_issues: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "fix the thing") {
		t.Fatalf("expected seeded issue, got: %s", got)
	}
}

func TestGetJiraIssueNotFound(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_jira_issue",
		Arguments: map[string]any{"key": "NOPE-1"},
	})
	if err != nil {
		t.Fatalf("call get_jira_issue: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected IsError for unknown key")
	}
}
