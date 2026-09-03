package jira

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateIssue_PostsFieldsWithADF(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodPost, r.Method)
		assert.Equal(t, "/rest/api/3/issue", r.URL.Path)
		assert.Equal(t, "application/json", r.Header.Get("Content-Type"))
		body, _ := io.ReadAll(r.Body)
		require.NoError(t, json.Unmarshal(body, &got))
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":"10001","key":"ABC-7","self":"https://x/rest/api/3/issue/10001"}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	created, err := c.CreateIssue(context.Background(), CreateIssueRequest{
		ProjectKey: "ABC", IssueType: "Task", Summary: "Fix login",
		Description: "First paragraph.\n\nSecond one.", Labels: []string{"backend"}, Priority: "High",
	})
	require.NoError(t, err)
	assert.Equal(t, "ABC-7", created.Key)

	fields := got["fields"].(map[string]any)
	assert.Equal(t, "ABC", fields["project"].(map[string]any)["key"])
	assert.Equal(t, "Task", fields["issuetype"].(map[string]any)["name"])
	assert.Equal(t, "Fix login", fields["summary"])
	assert.Equal(t, "High", fields["priority"].(map[string]any)["name"])
	assert.Equal(t, []any{"backend"}, fields["labels"])
	desc := fields["description"].(map[string]any)
	assert.Equal(t, "doc", desc["type"])
	assert.Len(t, desc["content"].([]any), 2)
}

func TestCreateIssue_OmitsEmptyOptionalFields(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":"1","key":"ABC-8"}`))
	}))
	defer srv.Close()
	_, err := makeTestClient(t, srv.URL).CreateIssue(context.Background(),
		CreateIssueRequest{ProjectKey: "ABC", IssueType: "Bug", Summary: "s"})
	require.NoError(t, err)
	fields := got["fields"].(map[string]any)
	_, hasDesc := fields["description"]
	_, hasPrio := fields["priority"]
	_, hasLabels := fields["labels"]
	assert.False(t, hasDesc)
	assert.False(t, hasPrio)
	assert.False(t, hasLabels)
}

func TestCreateIssue_MapsJiraErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"errorMessages":[],"errors":{"issuetype":"The issue type selected is invalid."}}`))
	}))
	defer srv.Close()
	_, err := makeTestClient(t, srv.URL).CreateIssue(context.Background(),
		CreateIssueRequest{ProjectKey: "ABC", IssueType: "Nope", Summary: "s"})
	var apiErr *APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, 400, apiErr.Status)
	assert.Contains(t, apiErr.Message, "issuetype: The issue type selected is invalid.")
}

func TestCreateIssue_ForbiddenIsAPIError403(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"errorMessages":["You do not have permission to create issues in this project."],"errors":{}}`))
	}))
	defer srv.Close()
	_, err := makeTestClient(t, srv.URL).CreateIssue(context.Background(),
		CreateIssueRequest{ProjectKey: "ABC", IssueType: "Task", Summary: "s"})
	var apiErr *APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, 403, apiErr.Status)
	assert.Contains(t, apiErr.Message, "permission")
}

// TestCreateIssue_401AfterRefreshIsAuthRevoked mirrors
// TestClient_PersistentUnauthorizedIsAuthRevoked (client_test.go) —
// JiraOAuthConfig has no TokenURL override, so the refresh endpoint is
// redirected via the package-level jiraTokenEndpoint var, the stubTokenEndpoint
// helper already used for this exact pattern.
func TestCreateIssue_401AfterRefreshIsAuthRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()
	stubTokenEndpoint(t)

	c := makeTestClient(t, srv.URL)
	_, err := c.CreateIssue(context.Background(), CreateIssueRequest{ProjectKey: "ABC", IssueType: "Task", Summary: "s"})
	assert.True(t, errors.Is(err, ErrAuthRevoked), "got %v", err)
}

func TestGetIssue_FetchesByKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/rest/api/3/issue/ABC-7", r.URL.Path)
		assert.Contains(t, r.URL.Query().Get("fields"), "summary")
		_, _ = w.Write([]byte(`{"id":"10001","key":"ABC-7","fields":{"summary":"Fix login","issuetype":{"name":"Task"},"status":{"name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"created":"2026-09-04T10:00:00.000+0000","updated":"2026-09-04T10:00:00.000+0000"}}`))
	}))
	defer srv.Close()
	issue, err := makeTestClient(t, srv.URL).GetIssue(context.Background(), "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "Fix login", issue.Fields.Summary)
	assert.Equal(t, "Task", issue.Fields.IssueType.Name)
}

func TestADFDocument_ParagraphsAndText(t *testing.T) {
	doc := ADFDocument("line one\nline two\n\nsecond para")
	assert.Equal(t, "doc", doc["type"])
	assert.Equal(t, 1, doc["version"])
	content := doc["content"].([]map[string]any)
	require.Len(t, content, 2)
	assert.Equal(t, "paragraph", content[0]["type"])
	assert.Equal(t, "line one\nline two", content[0]["content"].([]map[string]any)[0]["text"])
	assert.Equal(t, "second para", DescriptionText(map[string]interface{}{
		"type": "doc", "content": []interface{}{map[string]interface{}{"type": "paragraph",
			"content": []interface{}{map[string]interface{}{"type": "text", "text": "second para"}}}},
	}))
}
