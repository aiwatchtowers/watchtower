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
	comments, complete, _, err := c.getIssueComments(context.Background(), "PROJ-1")
	require.NoError(t, err)
	assert.True(t, complete)
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
	comments, complete, _, err := c.getIssueComments(context.Background(), "PROJ-1")
	require.NoError(t, err)
	assert.True(t, complete)
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
	comments, complete, _, err := c.getIssueComments(context.Background(), "PROJ-1")
	require.NoError(t, err)
	assert.Empty(t, comments)
	assert.False(t, complete)
}

// TestClient_GetIssueComments_MissingTotalIsIncomplete: a 200 without a
// total must not read as a complete, empty listing; total:0 still does.
func TestClient_GetIssueComments_MissingTotalIsIncomplete(t *testing.T) {
	for body, want := range map[string]bool{`{}`: false, `{"comments":[]}`: false, `{"total":0,"comments":[]}`: true} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(body))
		}))
		c := makeTestClient(t, srv.URL)
		comments, complete, _, err := c.getIssueComments(context.Background(), "PROJ-1")
		srv.Close()
		require.NoError(t, err)
		assert.Empty(t, comments)
		assert.Equal(t, want, complete, body)
	}
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
	_, _, _, err := c.getIssueComments(context.Background(), "PROJ-1")
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrAuthRevoked)
}

func TestClient_GetIssueComments_NonOKError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	_, _, _, err := c.getIssueComments(context.Background(), "PROJ-404")
	require.Error(t, err)
	assert.Contains(t, err.Error(), fmt.Sprintf("comments for %s", "PROJ-404"))
}

// TestClient_GetMyself_Success hits the same /ex/jira/<cloud> routing every
// other client test relies on and asserts all three identity fields by
// value — a fixture that only checks one field couldn't tell a swapped
// accountId/emailAddress from a correct response.
func TestClient_GetMyself_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Contains(t, r.URL.Path, "/rest/api/3/myself")
		_, _ = w.Write([]byte(`{"accountId":"acc-9","emailAddress":"j@x.com","displayName":"J Doe"}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	m, err := c.GetMyself(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "acc-9", m.AccountID)
	assert.Equal(t, "j@x.com", m.EmailAddress)
	assert.Equal(t, "J Doe", m.DisplayName)
}

func TestClient_GetMyself_NonOKError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	_, err := c.GetMyself(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "fetching myself")
}

// TestSearchIssueKeys_PagesToLast: two pages joined by a token come back as
// one complete listing, and every request asks for keys only.
func TestSearchIssueKeys_PagesToLast(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		assert.Equal(t, "/rest/api/3/search/jql", r.URL.Path)
		q := r.URL.Query()
		assert.Equal(t, "key", q.Get("fields"))
		assert.Equal(t, "5000", q.Get("maxResults"))
		assert.Equal(t, "project = PROJ ORDER BY key ASC", q.Get("jql"))
		if q.Get("nextPageToken") == "" {
			_, _ = w.Write([]byte(`{"issues":[{"id":"1","key":"PROJ-1"},{"id":"2","key":"PROJ-2"}],"isLast":false,"nextPageToken":"t2"}`))
			return
		}
		assert.Equal(t, "t2", q.Get("nextPageToken"))
		_, _ = w.Write([]byte(`{"issues":[{"id":"3","key":"PROJ-3"}],"isLast":true}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	keys, complete, err := c.searchIssueKeys(context.Background(), "project = PROJ ORDER BY key ASC")
	require.NoError(t, err)
	assert.True(t, complete)
	assert.Equal(t, []string{"PROJ-1", "PROJ-2", "PROJ-3"}, keys)
	assert.Equal(t, 2, calls)
}

func TestSearchIssueKeys_IncompleteWithoutToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"issues":[{"id":"1","key":"PROJ-1"}],"isLast":false}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	keys, complete, err := c.searchIssueKeys(context.Background(), "project = PROJ")
	require.NoError(t, err)
	assert.False(t, complete)
	assert.Equal(t, []string{"PROJ-1"}, keys)
}

func TestSearchIssueKeys_IncompleteOnMissingKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"issues":[{"id":"1","key":"PROJ-1"},{"id":"2"}],"isLast":true}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	_, complete, err := c.searchIssueKeys(context.Background(), "project = PROJ")
	require.NoError(t, err)
	assert.False(t, complete)
}

func TestSearchIssueKeys_IncompleteOnRepeatedToken(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		_, _ = w.Write([]byte(fmt.Sprintf(`{"issues":[{"id":"%d","key":"PROJ-%d"}],"isLast":false,"nextPageToken":"same"}`, calls, calls)))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	_, complete, err := c.searchIssueKeys(context.Background(), "project = PROJ")
	require.NoError(t, err)
	assert.False(t, complete)
	assert.Equal(t, 2, calls, "the repeated token stops the loop on the second page")
}

func TestSearchIssueKeys_ErrorIsReturned(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	keys, complete, err := c.searchIssueKeys(context.Background(), "project = PROJ")
	require.Error(t, err)
	assert.False(t, complete)
	assert.Empty(t, keys)
}

func TestIssueCurrentKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "key", r.URL.Query().Get("fields"))
		switch r.URL.Path {
		case "/rest/api/3/issue/PROJ-404":
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"errorMessages":["Issue does not exist or you do not have permission to see it."]}`))
		case "/rest/api/3/issue/PROJ-1":
			_, _ = w.Write([]byte(`{"id":"1","key":"PROJ-1"}`))
		case "/rest/api/3/issue/PROJ-6":
			_, _ = w.Write([]byte(`{"id":"6","key":"OTHER-9"}`))
		default:
			w.WriteHeader(http.StatusInternalServerError)
		}
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	ctx := context.Background()

	got, err := c.issueCurrentKey(ctx, "PROJ-404")
	require.NoError(t, err)
	assert.Equal(t, "", got)

	got, err = c.issueCurrentKey(ctx, "PROJ-1")
	require.NoError(t, err)
	assert.Equal(t, "PROJ-1", got)

	got, err = c.issueCurrentKey(ctx, "PROJ-6")
	require.NoError(t, err)
	assert.Equal(t, "OTHER-9", got)

	_, err = c.issueCurrentKey(ctx, "PROJ-500")
	require.Error(t, err)
}
