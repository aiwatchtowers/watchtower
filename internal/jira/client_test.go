package jira

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestClient_GetIssueComments_SinglePage covers the common case: one page
// covers the whole comment list, and an ADF comment body round-trips through
// extractDescriptionText the same way an issue description does.
func TestClient_GetIssueComments_SinglePage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Contains(t, r.URL.Path, "/rest/api/3/issue/PROJ-1/comment")
		q := r.URL.Query()
		assert.Equal(t, "0", q.Get("startAt"))
		assert.Equal(t, "50", q.Get("maxResults"))
		_, _ = w.Write([]byte(`{"startAt":0,"maxResults":50,"total":1,"comments":[
			{"id":"10001","author":{"displayName":"A","accountId":"acc-a"},
			 "body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"looks good"}]}]},
			 "created":"2026-01-01T00:00:00.000Z","updated":"2026-01-01T00:00:00.000Z"}
		]}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	comments, err := c.GetIssueComments(context.Background(), "PROJ-1")
	require.NoError(t, err)
	require.Len(t, comments, 1)
	assert.Equal(t, "10001", comments[0].ID)
	assert.Equal(t, "A", comments[0].Author.DisplayName)
	assert.Equal(t, "acc-a", comments[0].Author.AccountID)
	assert.Equal(t, "looks good", extractDescriptionText(comments[0].Body))
}

// TestClient_GetIssueComments_Paginates verifies the FetchAllBoards-shaped
// pagination: startAt advances by the page size until startAt+len >= total.
func TestClient_GetIssueComments_Paginates(t *testing.T) {
	var starts []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		startAt := r.URL.Query().Get("startAt")
		starts = append(starts, startAt)
		switch startAt {
		case "0":
			_, _ = w.Write([]byte(`{"startAt":0,"maxResults":2,"total":3,"comments":[
				{"id":"1","body":"first"},{"id":"2","body":"second"}]}`))
		default:
			_, _ = w.Write([]byte(`{"startAt":2,"maxResults":2,"total":3,"comments":[
				{"id":"3","body":"third"}]}`))
		}
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	comments, err := c.GetIssueComments(context.Background(), "PROJ-1")
	require.NoError(t, err)
	require.Len(t, comments, 3)
	assert.Equal(t, []string{"1", "2", "3"}, []string{comments[0].ID, comments[1].ID, comments[2].ID})
	assert.Equal(t, []string{"0", "2"}, starts)
}

// TestClient_GetIssueComments_StopsOnEmptyPage guards against an infinite
// loop if the API ever reports a total larger than what it actually returns.
func TestClient_GetIssueComments_StopsOnEmptyPage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"startAt":0,"maxResults":50,"total":99,"comments":[]}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	comments, err := c.GetIssueComments(context.Background(), "PROJ-1")
	require.NoError(t, err)
	assert.Empty(t, comments)
}

// TestClient_GetIssueComments_PropagatesAuthRevoked ensures a persistent 401
// surfaces as ErrAuthRevoked, not a plain "status 401" error — Syncer.Sync
// relies on errors.Is to decide whether to abort the whole account.
func TestClient_GetIssueComments_PropagatesAuthRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()
	stubTokenEndpoint(t)

	c := makeTestClient(t, srv.URL)
	_, err := c.GetIssueComments(context.Background(), "PROJ-1")
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrAuthRevoked)
}

func TestClient_GetIssueComments_NonOKError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	_, err := c.GetIssueComments(context.Background(), "PROJ-404")
	require.Error(t, err)
	assert.Contains(t, err.Error(), fmt.Sprintf("comments for %s", "PROJ-404"))
}
