package linear

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type capturedMutation struct {
	Query string
	Vars  map[string]any
}

// mutationClient is a Client against a server answering every GraphQL call with
// respond as the data object; the last request lands in *got.
func mutationClient(t *testing.T, respond map[string]any, got *capturedMutation) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		got.Query, got.Vars = req.Query, req.Variables
		_ = json.NewEncoder(w).Encode(map[string]any{"data": respond})
	}))
	t.Cleanup(srv.Close)
	store := NewTokenStore(t.TempDir(), 1)
	require.NoError(t, store.Save(&Token{AccessToken: "a0", RefreshToken: "r0",
		Expiry: time.Now().Add(time.Hour).Format(time.RFC3339)}))
	c := NewClient(OAuthConfig{ClientID: "cid"}, store)
	c.endpoint = srv.URL
	return c
}

// rawClient is a Client against a server answering every call with body.
func rawClient(t *testing.T, body string) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	store := NewTokenStore(t.TempDir(), 1)
	require.NoError(t, store.Save(&Token{AccessToken: "a0", RefreshToken: "r0",
		Expiry: time.Now().Add(time.Hour).Format(time.RFC3339)}))
	c := NewClient(OAuthConfig{ClientID: "cid"}, store)
	c.endpoint = srv.URL
	return c
}

func TestFetchIssueRef_FoundAndNotFound(t *testing.T) {
	var got capturedMutation
	c := mutationClient(t, map[string]any{"issue": map[string]any{"id": "u-1", "identifier": "ENG-9",
		"url": "https://linear.app/acme/issue/ENG-9"}}, &got)
	ref, found, err := c.FetchIssueRef(context.Background(), "u-1")
	require.NoError(t, err)
	assert.True(t, found)
	assert.Equal(t, IssueRef{ID: "u-1", Identifier: "ENG-9", URL: "https://linear.app/acme/issue/ENG-9"}, ref)
	assert.Equal(t, "u-1", got.Vars["id"])

	c = rawClient(t, `{"data":null,"errors":[{"message":"Entity not found: Issue","extensions":{"code":"INVALID_INPUT"}}]}`)
	_, found, err = c.FetchIssueRef(context.Background(), "u-2")
	require.NoError(t, err)
	assert.False(t, found)

	c = mutationClient(t, map[string]any{"issue": nil}, &got)
	_, found, err = c.FetchIssueRef(context.Background(), "u-3")
	require.NoError(t, err)
	assert.False(t, found)

	c = rawClient(t, `{"errors":[{"message":"boom","extensions":{"code":"INTERNAL"}}]}`)
	_, found, err = c.FetchIssueRef(context.Background(), "u-4")
	require.Error(t, err, "any other failure is an error, never 'not found'")
	assert.False(t, found)
}

func TestCreateIssue_SendsInput(t *testing.T) {
	var got capturedMutation
	c := mutationClient(t, map[string]any{"issueCreate": map[string]any{"success": true,
		"issue": map[string]any{"id": "i-9", "identifier": "ENG-9", "url": "https://linear.app/acme/issue/ENG-9"}}}, &got)
	prio := 2
	ref, err := c.CreateIssue(context.Background(), IssueCreateInput{ID: "6f1c2a3e-0000-4000-8000-000000000001", TeamID: "t-1", Title: "Fix it",
		Description: "body", StateID: "s-1", AssigneeID: "u-1", Priority: &prio, LabelIDs: []string{"l-1"}})
	require.NoError(t, err)
	assert.Equal(t, IssueRef{ID: "i-9", Identifier: "ENG-9", URL: "https://linear.app/acme/issue/ENG-9"}, ref)
	in, _ := got.Vars["input"].(map[string]any)
	assert.Equal(t, "6f1c2a3e-0000-4000-8000-000000000001", in["id"], "the client UUID is the issue's id")
	assert.Equal(t, "t-1", in["teamId"])
	assert.Equal(t, "Fix it", in["title"])
	assert.Equal(t, "body", in["description"])
	assert.Equal(t, "s-1", in["stateId"])
	assert.Equal(t, "u-1", in["assigneeId"])
	assert.EqualValues(t, 2, in["priority"])
	assert.Equal(t, []any{"l-1"}, in["labelIds"])
}

func TestUpdateIssue_UnassignSendsNull(t *testing.T) {
	var got capturedMutation
	c := mutationClient(t, map[string]any{"issueUpdate": map[string]any{"success": true}}, &got)
	empty := ""
	require.NoError(t, c.UpdateIssue(context.Background(), "i-1", IssueUpdateInput{AssigneeID: &empty}))
	assert.Equal(t, "i-1", got.Vars["id"])
	in, _ := got.Vars["input"].(map[string]any)
	v, present := in["assigneeId"]
	assert.True(t, present)
	assert.Nil(t, v)
	assert.Len(t, in, 1, "only set fields are sent")

	title := "New"
	require.NoError(t, c.UpdateIssue(context.Background(), "i-1", IssueUpdateInput{Title: &title}))
	in, _ = got.Vars["input"].(map[string]any)
	assert.NotContains(t, in, "assigneeId")
	assert.Equal(t, "New", in["title"])
}

func TestUpdateIssue_LabelDiff(t *testing.T) {
	var got capturedMutation
	c := mutationClient(t, map[string]any{"issueUpdate": map[string]any{"success": true}}, &got)
	require.NoError(t, c.UpdateIssue(context.Background(), "i-1",
		IssueUpdateInput{AddedLabelIDs: []string{"l-1"}, RemovedLabelIDs: []string{"l-2"}}))
	in, _ := got.Vars["input"].(map[string]any)
	assert.Equal(t, []any{"l-1"}, in["addedLabelIds"])
	assert.Equal(t, []any{"l-2"}, in["removedLabelIds"])
}

func TestCreateComment_ReturnsID(t *testing.T) {
	var got capturedMutation
	c := mutationClient(t, map[string]any{"commentCreate": map[string]any{"success": true,
		"comment": map[string]any{"id": "c-7"}}}, &got)
	id, err := c.CreateComment(context.Background(), "i-1", "hello")
	require.NoError(t, err)
	assert.Equal(t, "c-7", id)
	in, _ := got.Vars["input"].(map[string]any)
	assert.Equal(t, "i-1", in["issueId"])
	assert.Equal(t, "hello", in["body"])
}

func TestMutation_SuccessFalseIsError(t *testing.T) {
	var got capturedMutation
	c := mutationClient(t, map[string]any{
		"issueCreate":   map[string]any{"success": false, "issue": nil},
		"issueUpdate":   map[string]any{"success": false},
		"commentCreate": map[string]any{"success": false, "comment": nil},
	}, &got)
	_, err := c.CreateIssue(context.Background(), IssueCreateInput{TeamID: "t-1", Title: "x"})
	require.Error(t, err)
	require.Error(t, c.UpdateIssue(context.Background(), "i-1", IssueUpdateInput{}))
	_, err = c.CreateComment(context.Background(), "i-1", "x")
	require.Error(t, err)
}
