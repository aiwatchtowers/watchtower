package jira

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// makeTestClient constructs a Client wired to the given baseURL and a token
// store seeded with a valid (non-expired) access token.
func makeTestClient(t *testing.T, baseURL string) *Client {
	t.Helper()
	dir := t.TempDir()
	store := NewTokenStore(dir, 1)

	tok := &OAuthToken{
		AccessToken:  "at-valid",
		RefreshToken: "rt-valid",
		TokenType:    "Bearer",
		ExpiresIn:    3600,
		Expiry:       time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
	}
	require.NoError(t, store.Save(tok))

	c := &Client{
		cloudID:     "cloud-x",
		baseURL:     baseURL,
		oauthCfg:    JiraOAuthConfig{ClientID: "cid", ClientSecret: "secret"},
		tokenStore:  store,
		httpClient:  &http.Client{Timeout: 5 * time.Second},
		rateLimiter: NewRateLimiter(),
		logger:      log.New(io.Discard, "", 0),
	}
	return c
}

func TestNewClient_Initialization(t *testing.T) {
	store := NewTokenStore(t.TempDir(), 1)
	c := NewClient("c1", JiraOAuthConfig{}, store)
	assert.Equal(t, "c1", c.cloudID)
	assert.Contains(t, c.jiraBase(), "/ex/jira/c1")
	assert.NotNil(t, c.httpClient)
	assert.NotNil(t, c.rateLimiter)
	assert.NotNil(t, c.logger)
}

func TestClient_SetLogger(t *testing.T) {
	c := makeTestClient(t, "http://localhost")
	custom := log.New(io.Discard, "x", 0)
	c.SetLogger(custom)
	assert.Same(t, custom, c.logger)
}

func TestClient_Get_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "Bearer at-valid", r.Header.Get("Authorization"))
		assert.Equal(t, "application/json", r.Header.Get("Accept"))
		_, _ = w.Write([]byte(`{"name":"Acme"}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	var got struct {
		Name string `json:"name"`
	}
	require.NoError(t, c.get(context.Background(), "/rest/api/3/project/ABC", &got))
	assert.Equal(t, "Acme", got.Name)
}

func TestClient_Get_NonOK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"not found"}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	var got map[string]any
	err := c.get(context.Background(), "/missing", &got)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "status 404")
}

func TestClient_Get_BadJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	var got map[string]any
	err := c.get(context.Background(), "/x", &got)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "decoding")
}

func TestClient_RefreshOn401(t *testing.T) {
	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		switch calls {
		case 1:
			// First call uses old token → reject as 401.
			w.WriteHeader(http.StatusUnauthorized)
		default:
			// After refresh, second call must use refreshed token.
			assert.Equal(t, "Bearer at-refreshed", r.Header.Get("Authorization"))
			_, _ = w.Write([]byte(`{"ok":true}`))
		}
	}))
	defer srv.Close()

	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"at-refreshed","refresh_token":"rt2","expires_in":3600}`))
	}))
	defer tokenSrv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = tokenSrv.URL
	defer func() { jiraTokenEndpoint = prev }()

	c := makeTestClient(t, srv.URL)
	var got map[string]any
	require.NoError(t, c.get(context.Background(), "/x", &got))
	assert.Equal(t, true, got["ok"])
	assert.Equal(t, 2, calls)
}

// TestClient_PersistentUnauthorizedIsAuthRevoked pins the distinction the whole
// re-login chain rests on: a 401 that survives a successful token refresh is
// not a stale access token, it is a grant that is gone. Only ErrAuthRevoked
// makes Syncer.Sync abort and the daemon stamp the account for re-login; a
// plain "status 401" error would be swallowed per project.
func TestClient_PersistentUnauthorizedIsAuthRevoked(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	stubTokenEndpoint(t)

	c := makeTestClient(t, srv.URL)
	var got map[string]any
	err := c.get(context.Background(), "/x", &got)

	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked), "a 401 surviving a refresh must read as a revoked grant")
	assert.Equal(t, int32(4), calls.Load(), "the client must retry through its refresh budget before giving up")
}

// TestClient_PersistentUnauthorizedScopeIsNotRevoked: Atlassian answers a
// request the grant lacks a scope for with 401 "Unauthorized; scope does
// not match". That grant is alive and needs re-consent, so the surviving 401
// comes back as *HTTPStatusError carrying the body, never as ErrAuthRevoked —
// and, since refreshing an access token can never fix a missing scope, it
// must surface on the very first response rather than after burning the
// refresh-token rotation budget (a scope-denied 401 used to rotate the
// refresh token three times before this classification kicked in).
func TestClient_PersistentUnauthorizedScopeIsNotRevoked(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"code":401,"message":"Unauthorized; SCOPE DOES NOT MATCH"}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	var got map[string]any
	err := c.get(context.Background(), "/x", &got)

	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrAuthRevoked), "a missing scope is not a revoked grant")
	var he *HTTPStatusError
	require.True(t, errors.As(err, &he), "got %v", err)
	assert.Equal(t, http.StatusUnauthorized, he.Status)
	assert.Contains(t, he.Body, "SCOPE DOES NOT MATCH")
	assert.Equal(t, int32(1), calls.Load(), "a scope-denied 401 must surface immediately, with no refresh attempt")
}

// TestClient_401AfterRateLimitedAttemptsStillRefreshes pins the fix for the
// 401/429 counter split: three 429s (e.g. the access token expiring mid
// backoff) must not spend the 401 refresh budget — a 401 arriving right
// after them must still get its own three refresh attempts, not be declared
// ErrAuthRevoked immediately. Each 429 response carries "Retry-After: 0" so
// the test does not sleep through BackoffDuration's fixed schedule.
func TestClient_401AfterRateLimitedAttemptsStillRefreshes(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch calls.Add(1) {
		case 1, 2, 3:
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
		case 4:
			w.WriteHeader(http.StatusUnauthorized)
		default:
			assert.Equal(t, "Bearer at-refreshed", r.Header.Get("Authorization"))
			_, _ = w.Write([]byte(`{"ok":true}`))
		}
	}))
	defer srv.Close()

	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"at-refreshed","refresh_token":"rt2","expires_in":3600}`))
	}))
	defer tokenSrv.Close()
	prev := jiraTokenEndpoint
	jiraTokenEndpoint = tokenSrv.URL
	defer func() { jiraTokenEndpoint = prev }()

	c := makeTestClient(t, srv.URL)
	var got map[string]any
	require.NoError(t, c.get(context.Background(), "/x", &got))
	assert.Equal(t, true, got["ok"])
	assert.Equal(t, int32(5), calls.Load(), "3 rate-limit retries + 1 failing 401 + 1 refreshed retry")
}

// TestClient_RateLimitExhaustedPreservesStatus pins that giving up on a 429
// still lets a caller tell it was a rate limit: the returned error wraps the
// response's own *HTTPStatusError (status 429) instead of a bare
// "max retries exceeded" string with no status attached.
func TestClient_RateLimitExhaustedPreservesStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "0")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"message":"rate limited"}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	var got map[string]any
	err := c.get(context.Background(), "/x", &got)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "max retries exceeded")
	var he *HTTPStatusError
	require.True(t, errors.As(err, &he), "got %v", err)
	assert.Equal(t, http.StatusTooManyRequests, he.Status)
	assert.Contains(t, he.Body, "rate limited")
}

func TestClient_SearchIssues(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Contains(t, r.URL.Path, "/rest/api/3/search/jql")
		q := r.URL.Query()
		assert.Equal(t, "project = ABC", q.Get("jql"))
		assert.Equal(t, "10", q.Get("maxResults"))
		_, _ = w.Write([]byte(`{"issues":[{"key":"ABC-1"}],"total":1,"nextPageToken":"page2"}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	res, err := c.SearchIssues(context.Background(), "project = ABC", 10, "")
	require.NoError(t, err)
	require.Len(t, res.Issues, 1)
	assert.Equal(t, "ABC-1", res.Issues[0].Key)
	assert.Equal(t, "page2", res.NextPageToken)
}

func TestClient_SearchIssues_Paginated(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.URL.Query().Get("nextPageToken")
		_, _ = w.Write([]byte(`{"issues":[],"total":0}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	_, err := c.SearchIssues(context.Background(), "x", 50, "abc-token")
	require.NoError(t, err)
	assert.Equal(t, "abc-token", got)
}

func TestClient_FetchAllBoards_Pagination(t *testing.T) {
	var n int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n++
		switch n {
		case 1:
			_, _ = w.Write([]byte(`{"isLast":false,"values":[{"id":1,"name":"A"},{"id":2,"name":"B"}]}`))
		default:
			_, _ = w.Write([]byte(`{"isLast":true,"values":[{"id":3,"name":"C"}]}`))
		}
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	boards, err := c.FetchAllBoards(context.Background())
	require.NoError(t, err)
	require.Len(t, boards, 3)
	assert.Equal(t, 1, boards[0].ID)
	assert.Equal(t, 3, boards[2].ID)
}

func TestClient_FetchAllBoards_StopOnEmptyPage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"isLast":false,"values":[]}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	boards, err := c.FetchAllBoards(context.Background())
	require.NoError(t, err)
	assert.Empty(t, boards)
}

func TestClient_FetchBoardIssueCount(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Contains(t, r.URL.Path, "/rest/agile/1.0/board/42/issue")
		_, _ = w.Write([]byte(`{"total":17,"issues":[]}`))
	}))
	defer srv.Close()

	c := makeTestClient(t, srv.URL)
	n, err := c.FetchBoardIssueCount(context.Background(), 42)
	require.NoError(t, err)
	assert.Equal(t, 17, n)
}

func TestClient_GetAccessToken_Refreshes(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 1)
	// Save expired token.
	require.NoError(t, store.Save(&OAuthToken{
		AccessToken:  "old",
		RefreshToken: "rt",
		Expiry:       time.Now().Add(-time.Hour).UTC().Format(time.RFC3339),
	}))

	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"new","refresh_token":"rt2","expires_in":3600}`))
	}))
	defer tokenSrv.Close()
	prev := jiraTokenEndpoint
	jiraTokenEndpoint = tokenSrv.URL
	defer func() { jiraTokenEndpoint = prev }()

	c := &Client{
		baseURL:     "http://x",
		oauthCfg:    JiraOAuthConfig{ClientID: "c", ClientSecret: "s"},
		tokenStore:  store,
		httpClient:  &http.Client{Timeout: 3 * time.Second},
		rateLimiter: NewRateLimiter(),
		logger:      log.New(io.Discard, "", 0),
	}
	at, err := c.getAccessToken(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "new", at)

	// Token store should have been overwritten.
	loaded, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "new", loaded.AccessToken)
}

func TestClient_GetAccessToken_PreservesRefreshTokenOnEmptyResponse(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 1)
	require.NoError(t, store.Save(&OAuthToken{
		AccessToken:  "old",
		RefreshToken: "keep-me",
		Expiry:       time.Now().Add(-time.Hour).UTC().Format(time.RFC3339),
	}))

	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		// No refresh_token in response.
		_, _ = w.Write([]byte(`{"access_token":"new","expires_in":3600}`))
	}))
	defer tokenSrv.Close()
	prev := jiraTokenEndpoint
	jiraTokenEndpoint = tokenSrv.URL
	defer func() { jiraTokenEndpoint = prev }()

	c := &Client{
		oauthCfg:   JiraOAuthConfig{},
		tokenStore: store,
		httpClient: &http.Client{Timeout: 3 * time.Second},
		logger:     log.New(io.Discard, "", 0),
	}
	_, err := c.getAccessToken(context.Background())
	require.NoError(t, err)

	loaded, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "keep-me", loaded.RefreshToken, "client must preserve refresh_token when missing in response")
}

// TestClient_GetAccessToken_CrossProcessRefreshOnce: two Clients on the same
// token file stand in for the daemon and a concurrent CLI — separate
// in-process mutexes, one shared file. Atlassian rotates the refresh token, so
// only the first refresh may reach the token endpoint; the second must wait on
// the file lock and pick up the already-refreshed token instead of failing
// with invalid_grant.
func TestClient_GetAccessToken_CrossProcessRefreshOnce(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, NewTokenStore(dir, 1).Save(&OAuthToken{
		AccessToken:  "old",
		RefreshToken: "rt",
		Expiry:       time.Now().Add(-time.Hour).UTC().Format(time.RFC3339),
	}))

	var calls atomic.Int32
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) > 1 {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
			return
		}
		time.Sleep(100 * time.Millisecond) // widen the race window
		_, _ = w.Write([]byte(`{"access_token":"new","refresh_token":"rt2","expires_in":3600}`))
	}))
	defer tokenSrv.Close()

	newClient := func() *Client {
		return &Client{
			oauthCfg:   JiraOAuthConfig{ClientID: "c", ClientSecret: "s"},
			tokenStore: NewTokenStore(dir, 1),
			httpClient: &http.Client{Timeout: 3 * time.Second},
			logger:     log.New(io.Discard, "", 0),
			tokenURL:   tokenSrv.URL,
		}
	}
	clients := []*Client{newClient(), newClient()}

	var wg sync.WaitGroup
	tokens := make([]string, len(clients))
	errs := make([]error, len(clients))
	for i, c := range clients {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tokens[i], errs[i] = c.getAccessToken(context.Background())
		}()
	}
	wg.Wait()

	for i := range clients {
		require.NoError(t, errs[i], "client %d", i)
		assert.Equal(t, "new", tokens[i], "client %d", i)
	}
	assert.Equal(t, int32(1), calls.Load(), "the token endpoint must be hit once across both clients")
}

// TestClient_RefreshIfCurrent_CrossProcessRefreshOnce: the 401 path. Two
// Clients (daemon + CLI) on one token file both got a 401 for the same stale
// access token; only one may refresh — the other sees the rotated token
// under the file lock and returns without calling the token endpoint.
func TestClient_RefreshIfCurrent_CrossProcessRefreshOnce(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, NewTokenStore(dir, 1).Save(&OAuthToken{
		AccessToken:  "stale",
		RefreshToken: "rt",
		Expiry:       time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
	}))

	var calls atomic.Int32
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) > 1 {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
			return
		}
		time.Sleep(100 * time.Millisecond) // widen the race window
		_, _ = w.Write([]byte(`{"access_token":"new","refresh_token":"rt2","expires_in":3600}`))
	}))
	defer tokenSrv.Close()

	newClient := func() *Client {
		return &Client{
			oauthCfg:   JiraOAuthConfig{ClientID: "c", ClientSecret: "s"},
			tokenStore: NewTokenStore(dir, 1),
			httpClient: &http.Client{Timeout: 3 * time.Second},
			logger:     log.New(io.Discard, "", 0),
			tokenURL:   tokenSrv.URL,
		}
	}
	clients := []*Client{newClient(), newClient()}

	var wg sync.WaitGroup
	errs := make([]error, len(clients))
	for i, c := range clients {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = c.refreshIfCurrent(context.Background(), "stale")
		}()
	}
	wg.Wait()

	for i := range clients {
		require.NoError(t, errs[i], "client %d", i)
	}
	assert.Equal(t, int32(1), calls.Load(), "the token endpoint must be hit once across both clients")
}
