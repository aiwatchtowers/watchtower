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
	db.SeedTestJiraAccount(t, database)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1,
		Key:       "ABC-1", ID: "ABC-1", ProjectKey: "ABC", Summary: "fix the thing",
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

func TestGetJiraIssue(t *testing.T) {
	database := seedDB(t)
	db.SeedTestJiraAccount(t, database)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1,
		Key:       "ABC-7", ID: "ABC-7", ProjectKey: "ABC", Summary: "wire the widget",
		Status: "In Progress", StatusCategory: "In Progress",
		CreatedAt: "2026-06-01T00:00:00Z", UpdatedAt: "2026-06-02T00:00:00Z",
		SyncedAt: "2026-06-02T00:00:00Z",
	}); err != nil {
		t.Fatalf("seeding jira issue: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_jira_issue",
		Arguments: map[string]any{"key": "ABC-7"},
	})
	if err != nil {
		t.Fatalf("call get_jira_issue: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "wire the widget") {
		t.Fatalf("expected issue summary, got: %s", got)
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

// TestGetJiraIssueDeleted guards C2: a soft-deleted (tombstoned) issue must be
// treated as not-found, consistent with list_jira_issues (which filters
// is_deleted = 0).
func TestGetJiraIssueDeleted(t *testing.T) {
	database := seedDB(t)
	db.SeedTestJiraAccount(t, database)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1,
		Key:       "ABC-9", ID: "ABC-9", ProjectKey: "ABC", Summary: "deleted issue",
		Status: "Done", StatusCategory: "Done",
		CreatedAt: "2026-06-01T00:00:00Z", UpdatedAt: "2026-06-02T00:00:00Z",
		SyncedAt: "2026-06-02T00:00:00Z", IsDeleted: true,
	}); err != nil {
		t.Fatalf("seeding deleted jira issue: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_jira_issue",
		Arguments: map[string]any{"key": "ABC-9"},
	})
	if err != nil {
		t.Fatalf("call get_jira_issue: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected IsError for a tombstoned issue, got: %s", textContent(t, res))
	}
}
