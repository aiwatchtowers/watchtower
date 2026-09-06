package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func jiraReadRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewListJiraIssues()))
	require.NoError(t, reg.Register(NewGetJiraIssue()))
	return reg
}

func seedJiraIssue(t *testing.T, d *db.DB, key, summary string, deleted bool) {
	t.Helper()
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1, Key: key, ID: key, ProjectKey: "ABC", Summary: summary,
		Status: "To Do", StatusCategory: "To Do",
		CreatedAt: "2026-06-01T00:00:00Z", UpdatedAt: "2026-06-02T00:00:00Z", SyncedAt: "2026-06-02T00:00:00Z",
		IsDeleted: deleted,
	}))
}

func TestListJiraIssues_ByProject(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, "ABC-1", "fix the thing", false)

	got := callReadString(t, jiraReadRegistry(t, d), "list_jira_issues", `{"project":"ABC"}`)
	assert.Contains(t, got, "fix the thing")
}

func TestGetJiraIssue_ReturnsIssue(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, "ABC-7", "wire the widget", false)

	got := callReadString(t, jiraReadRegistry(t, d), "get_jira_issue", `{"key":"ABC-7"}`)
	assert.Contains(t, got, "wire the widget")
}

func TestGetJiraIssue_NotFound(t *testing.T) {
	_, err := jiraReadRegistry(t, openDB(t)).CallRead(context.Background(), "get_jira_issue", json.RawMessage(`{"key":"NOPE-1"}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no jira issue with key NOPE-1")
}

// A soft-deleted (tombstoned) issue is treated as not-found, consistent with
// list_jira_issues (which filters is_deleted = 0).
func TestGetJiraIssue_TombstoneIsNotFound(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, "ABC-9", "deleted issue", true)

	_, err := jiraReadRegistry(t, d).CallRead(context.Background(), "get_jira_issue", json.RawMessage(`{"key":"ABC-9"}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no jira issue with key ABC-9")
}
