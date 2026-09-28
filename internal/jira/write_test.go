package jira

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// recordingServer answers every request with status/body and records the
// last method, path, raw query and decoded JSON body.
type recorded struct {
	method, path, query string
	body                map[string]any
}

func recordingServer(t *testing.T, status int, respBody string, rec *recorded) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.method, rec.path, rec.query = r.Method, r.URL.Path, r.URL.RawQuery
		raw, _ := io.ReadAll(r.Body)
		rec.body = nil
		if len(raw) > 0 {
			require.NoError(t, json.Unmarshal(raw, &rec.body))
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(respBody))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestAddComment_PostsADFBodyAndReturnsID(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusCreated, `{"id":"10042"}`, &rec)
	id, err := makeTestClient(t, srv.URL).AddComment(context.Background(), "ABC-7", "First.\n\nSecond.")
	require.NoError(t, err)
	assert.Equal(t, "10042", id)
	assert.Equal(t, http.MethodPost, rec.method)
	assert.Equal(t, "/rest/api/3/issue/ABC-7/comment", rec.path)
	body := rec.body["body"].(map[string]any)
	assert.Equal(t, "doc", body["type"])
	assert.Len(t, body["content"].([]any), 2, "blank line splits paragraphs")
}

func TestAddComment_EmptyBodyNeverCallsJira(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusCreated, `{"id":"1"}`, &rec)
	_, err := makeTestClient(t, srv.URL).AddComment(context.Background(), "ABC-7", "  \n ")
	require.Error(t, err)
	assert.Empty(t, rec.method, "no request for an empty comment")
}

func TestGetTransitions_Decodes(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusOK,
		`{"transitions":[{"id":"21","name":"Start","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},{"id":"31","name":"Finish","to":{"name":"Done","statusCategory":{"key":"done"}}}]}`, &rec)
	ts, err := makeTestClient(t, srv.URL).GetTransitions(context.Background(), "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "/rest/api/3/issue/ABC-7/transitions", rec.path)
	require.Len(t, ts, 2)
	assert.Equal(t, "21", ts[0].ID)
	assert.Equal(t, "In Progress", ts[0].To.Name)
	assert.Equal(t, "done", ts[1].To.StatusCategory.Key)
}

func TestTransitionIssue_PostsTransitionID(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	require.NoError(t, makeTestClient(t, srv.URL).TransitionIssue(context.Background(), "ABC-7", "31"))
	assert.Equal(t, http.MethodPost, rec.method)
	assert.Equal(t, "/rest/api/3/issue/ABC-7/transitions", rec.path)
	assert.Equal(t, "31", rec.body["transition"].(map[string]any)["id"])
}

func TestAssignIssue_PutsAccountID(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	require.NoError(t, makeTestClient(t, srv.URL).AssignIssue(context.Background(), "ABC-7", "acc-1"))
	assert.Equal(t, http.MethodPut, rec.method)
	assert.Equal(t, "/rest/api/3/issue/ABC-7/assignee", rec.path)
	assert.Equal(t, "acc-1", rec.body["accountId"])
}

func TestUpdateIssue_SendsFieldsAndLabelOps(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	summary, prio, due := "New title", "High", "2026-10-01"
	err := makeTestClient(t, srv.URL).UpdateIssue(context.Background(), "ABC-7", IssueUpdate{
		Summary: &summary, Priority: &prio, DueDate: &due,
		LabelsAdd: []string{"backend"}, LabelsRemove: []string{"stale"},
	})
	require.NoError(t, err)
	assert.Equal(t, http.MethodPut, rec.method)
	assert.Equal(t, "/rest/api/3/issue/ABC-7", rec.path)
	fields := rec.body["fields"].(map[string]any)
	assert.Equal(t, "New title", fields["summary"])
	assert.Equal(t, "High", fields["priority"].(map[string]any)["name"])
	assert.Equal(t, "2026-10-01", fields["duedate"])
	labels := rec.body["update"].(map[string]any)["labels"].([]any)
	assert.Equal(t, []any{map[string]any{"add": "backend"}, map[string]any{"remove": "stale"}}, labels)
}

func TestUpdateIssue_LabelsOnlyOmitsFields(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	require.NoError(t, makeTestClient(t, srv.URL).UpdateIssue(context.Background(), "ABC-7",
		IssueUpdate{LabelsAdd: []string{"x"}}))
	_, hasFields := rec.body["fields"]
	assert.False(t, hasFields)
}

func TestUpdateIssue_EmptyUpdateNeverCallsJira(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	require.Error(t, makeTestClient(t, srv.URL).UpdateIssue(context.Background(), "ABC-7", IssueUpdate{}))
	assert.Empty(t, rec.method)
}

func TestSearchUsers_QueriesAndDecodes(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusOK,
		`[{"accountId":"acc-1","displayName":"Jane Doe","emailAddress":"jane@example.com","active":true,"accountType":"atlassian"}]`, &rec)
	users, err := makeTestClient(t, srv.URL).SearchUsers(context.Background(), "jane")
	require.NoError(t, err)
	assert.Equal(t, "/rest/api/3/user/search", rec.path)
	assert.Contains(t, rec.query, "query=jane")
	require.Len(t, users, 1)
	assert.Equal(t, "atlassian", users[0].AccountType)
}

func TestWrites_MapJiraErrors(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusBadRequest, `{"errorMessages":[],"errors":{"priority":"Priority name 'Urgent' is not valid"}}`, &rec)
	prio := "Urgent"
	err := makeTestClient(t, srv.URL).UpdateIssue(context.Background(), "ABC-7", IssueUpdate{Priority: &prio})
	var apiErr *APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, 400, apiErr.Status)
	assert.Contains(t, apiErr.Message, "priority: Priority name 'Urgent' is not valid")
}

func TestMatchTransition_ByTargetStatusThenName(t *testing.T) {
	ts := []Transition{
		{ID: "21", Name: "Start work", To: Status{Name: "In Progress"}},
		{ID: "31", Name: "Close", To: Status{Name: "Done"}},
	}
	got, ok := MatchTransition(ts, " done ")
	require.True(t, ok)
	assert.Equal(t, "31", got.ID)
	got, ok = MatchTransition(ts, "start WORK")
	require.True(t, ok)
	assert.Equal(t, "21", got.ID)
	_, ok = MatchTransition(ts, "Review")
	assert.False(t, ok)
	assert.Equal(t, []string{"In Progress", "Done"}, TransitionTargets(append(ts, Transition{ID: "41", To: Status{Name: "Done"}})))
}
