package jira

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newTestClient constructs a Client via NewClient (so it picks up the real
// apiRoot/tokenURL defaults) with a token store seeded with accessToken (not
// expired), then overrides the apiRoot/tokenURL test seams to point both the
// Jira and Confluence bases, and token refreshes, at local httptest servers.
// An empty tokenURL leaves the client's refreshes on the package's
// jiraTokenEndpoint var (see tokenEndpoint) for tests that never refresh.
func newTestClient(t *testing.T, apiBase, tokenURL, accessToken string) *Client {
	t.Helper()
	store := NewTokenStore(t.TempDir(), 1)
	require.NoError(t, store.Save(&OAuthToken{
		AccessToken:  accessToken,
		RefreshToken: "rt-valid",
		Scope:        OAuthScopes,
		Expiry:       time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
	}))

	c := NewClient("cloud1", JiraOAuthConfig{ClientID: "id", ClientSecret: "s"}, store)
	c.apiRoot = apiBase
	c.tokenURL = tokenURL
	return c
}

// getJSONForTest is a tiny test-only wrapper over the unexported Jira get, so
// TestConcurrent401sRefreshOnce can drive both a Jira and a Confluence
// request through the same Client concurrently.
func (c *Client) getJSONForTest(ctx context.Context, path string) error {
	var out map[string]any
	return c.get(ctx, path, &out)
}

// TestConcurrent401sRefreshOnce pins the single-flight refresh guard: with
// Atlassian's rotating refresh tokens, two overlapping 401s racing the same
// stale access token must trigger exactly ONE call to the token endpoint —
// a second concurrent refresh would reuse an already-rotated refresh_token
// and fail with invalid_grant, effectively revoking the grant. Every
// goroutine here shares one Client, mixing Jira (c.getJSONForTest) and
// Confluence (c.Confluence().GetJSON) requests, since a later task runs up
// to 4 Confluence requests in parallel on the same Client.
func TestConcurrent401sRefreshOnce(t *testing.T) {
	var refreshes atomic.Int32
	var good atomic.Value
	good.Store("old")
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+good.Load().(string) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer api.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		refreshes.Add(1)
		time.Sleep(50 * time.Millisecond)
		good.Store("new")
		_, _ = w.Write([]byte(`{"access_token":"new","refresh_token":"rt2","expires_in":3600,"scope":"s"}`))
	}))
	defer tokenSrv.Close()

	c := newTestClient(t, api.URL, tokenSrv.URL, "stale") // helper: stored token "stale", not expired
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); _ = c.getJSONForTest(context.Background(), "/rest/api/3/myself") }()
		go func() {
			defer wg.Done()
			var out map[string]any
			_ = c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &out)
		}()
	}
	wg.Wait()
	assert.Equal(t, int32(1), refreshes.Load())
}

// TestConcurrent401sRefreshOnce_PreservesScopeOnRefresh pins the Step 4
// carry-over rule: the token server's refresh response here omits "scope"
// entirely (Atlassian does not guarantee it on every refresh response), so
// the stored token after refresh must keep the pre-refresh Scope rather than
// have it blanked out — an empty Scope would make HasConfluenceScopes start
// reporting false for a grant that never actually lost Confluence access.
func TestConcurrent401sRefreshOnce_PreservesScopeOnRefresh(t *testing.T) {
	var good atomic.Value
	good.Store("old")
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+good.Load().(string) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer api.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		good.Store("new")
		// No "scope" field in the refresh response.
		_, _ = w.Write([]byte(`{"access_token":"new","refresh_token":"rt2","expires_in":3600}`))
	}))
	defer tokenSrv.Close()

	c := newTestClient(t, api.URL, tokenSrv.URL, "stale")
	require.NoError(t, c.getJSONForTest(context.Background(), "/rest/api/3/myself"))

	tok, err := c.tokenStore.Load()
	require.NoError(t, err)
	assert.Equal(t, OAuthScopes, tok.Scope, "scope must be carried over when the refresh response omits it")
}

func TestConfluenceDownloadCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(bytes.Repeat([]byte("a"), 100))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	rc, err := c.Confluence().Download(context.Background(), "/wiki/download/x", 10)
	if err == nil {
		_, err = io.ReadAll(rc)
		rc.Close()
	}
	assert.ErrorIs(t, err, ErrTooLarge)
}

// TestConfluenceDownloadCap_NoContentLengthHint forces the io.LimitReader
// enforcement path specifically: chunked transfer encoding (via Flush mid-
// handler) means resp.ContentLength is -1, so Download cannot fail fast on
// the Content-Length check alone and must rely on capping the read itself.
func TestConfluenceDownloadCap_NoContentLengthHint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		require.True(t, ok)
		_, _ = w.Write([]byte("aaaaa"))
		flusher.Flush()
		_, _ = w.Write([]byte("aaaaa"))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	rc, err := c.Confluence().Download(context.Background(), "/wiki/download/x", 5)
	require.NoError(t, err, "no Content-Length hint must not fail before any bytes are read")
	_, err = io.ReadAll(rc)
	rc.Close()
	assert.ErrorIs(t, err, ErrTooLarge)
}

func TestConfluenceDownloadCap_ExactlyAtCapSucceeds(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(bytes.Repeat([]byte("a"), 10))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	rc, err := c.Confluence().Download(context.Background(), "/wiki/download/x", 10)
	require.NoError(t, err)
	data, err := io.ReadAll(rc)
	require.NoError(t, err)
	rc.Close()
	assert.Len(t, data, 10)
}

func TestConfluenceDownload_NonOKStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte("gone"))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	_, err := c.Confluence().Download(context.Background(), "/wiki/download/x", 100)
	var statusErr *HTTPStatusError
	require.ErrorAs(t, err, &statusErr)
	assert.Equal(t, 404, statusErr.Status)
	assert.Contains(t, statusErr.Body, "gone")
}

func TestConfluenceGetJSONOnlyGET(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodGet, r.Method)
		assert.True(t, strings.HasPrefix(r.URL.Path, "/ex/confluence/cloud1/wiki/"), r.URL.Path)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	var out struct{ OK bool }
	require.NoError(t, c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", url.Values{"limit": {"1"}}, &out))
	assert.True(t, out.OK)
}

func TestConfluenceGetJSON_QueryEncoded(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "1", r.URL.Query().Get("limit"))
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	var out map[string]any
	require.NoError(t, c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", url.Values{"limit": {"1"}}, &out))
}

func TestConfluenceGetJSON_NonOKStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"message":"does not match the required scope"}`))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	var out map[string]any
	err := c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &out)
	var statusErr *HTTPStatusError
	require.ErrorAs(t, err, &statusErr)
	assert.Equal(t, 403, statusErr.Status)
	assert.Contains(t, statusErr.Body, "scope")
	assert.Contains(t, statusErr.Error(), "403")
}

// TestConfluenceGetJSON_SuccessBodyCap pins that a 2xx response is bounded
// the same way Download already is: a body over the cap fails loudly with
// ErrTooLarge instead of json.Decode reading (or OOMing on) it unbounded.
func TestConfluenceGetJSON_SuccessBodyCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(bytes.Repeat([]byte("a"), maxSuccessBodyBytes+1))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	var out map[string]any
	err := c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &out)
	assert.ErrorIs(t, err, ErrTooLarge)
}

// TestConfluenceGetJSON_ExactlyAtCapSucceeds pins the boundary: a body of
// exactly maxSuccessBodyBytes is still read and decoded normally.
func TestConfluenceGetJSON_ExactlyAtCapSucceeds(t *testing.T) {
	const wrapper = 10 // len(`{"pad":""}`)
	padLen := maxSuccessBodyBytes - wrapper
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := append([]byte(`{"pad":"`), bytes.Repeat([]byte("a"), padLen)...)
		body = append(body, []byte(`"}`)...)
		_, _ = w.Write(body)
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	var out struct {
		Pad string `json:"pad"`
	}
	require.NoError(t, c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &out))
	assert.Len(t, out.Pad, padLen)
}

// TestConfluenceDownload_OmitsJSONAcceptHeader pins that Download never sends
// Accept: application/json — an attachment binary is not JSON, and telling
// Confluence's download endpoint to expect one is wrong for this request
// (unlike GetJSON, which correctly keeps it).
func TestConfluenceDownload_OmitsJSONAcceptHeader(t *testing.T) {
	var gotAccept string
	var sawHeader bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAccept, sawHeader = r.Header.Get("Accept"), len(r.Header.Values("Accept")) > 0
		_, _ = w.Write([]byte("binary-ish"))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")

	rc, err := c.Confluence().Download(context.Background(), "/wiki/download/x", 100)
	require.NoError(t, err)
	_, _ = io.ReadAll(rc)
	rc.Close()

	assert.False(t, sawHeader, "Download must not send an Accept header at all")
	assert.NotEqual(t, "application/json", gotAccept)
}

// TestConfluencePutJSON_SendsPUTWithJSONBody pins PutJSON's request shape:
// method PUT, the same "/ex/confluence/<cloud>/wiki/..." base GetJSON uses,
// Content-Type/Accept application/json, the marshaled body, and the 2xx
// response decoded into out.
func TestConfluencePutJSON_SendsPUTWithJSONBody(t *testing.T) {
	var gotMethod, gotPath, gotContentType, gotAccept, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotContentType = r.Header.Get("Content-Type")
		gotAccept = r.Header.Get("Accept")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		_, _ = w.Write([]byte(`{"id":"1","version":{"number":2}}`))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")

	type putBody struct {
		ID      string `json:"id"`
		Version int    `json:"version"`
	}
	var out struct {
		ID      string `json:"id"`
		Version struct {
			Number int `json:"number"`
		} `json:"version"`
	}
	err := c.Confluence().PutJSON(context.Background(), "/wiki/api/v2/pages/1", putBody{ID: "1", Version: 2}, &out)
	require.NoError(t, err)

	assert.Equal(t, http.MethodPut, gotMethod)
	assert.Equal(t, "/ex/confluence/cloud1/wiki/api/v2/pages/1", gotPath)
	assert.Equal(t, "application/json", gotContentType)
	assert.Equal(t, "application/json", gotAccept)
	assert.JSONEq(t, `{"id":"1","version":2}`, gotBody)
	assert.Equal(t, "1", out.ID)
	assert.Equal(t, 2, out.Version.Number)
}

// TestConfluencePutJSON_NonOKStatus pins that a non-2xx PUT response (a 409
// version conflict, the real-world shape a stale-version edit gets back)
// surfaces as *HTTPStatusError rather than being decoded.
func TestConfluencePutJSON_NonOKStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"message":"version conflict"}`))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")

	var out map[string]any
	err := c.Confluence().PutJSON(context.Background(), "/wiki/api/v2/pages/1", map[string]any{"id": "1"}, &out)
	var statusErr *HTTPStatusError
	require.ErrorAs(t, err, &statusErr)
	assert.Equal(t, 409, statusErr.Status)
	assert.Contains(t, statusErr.Body, "version conflict")
}

// TestConfluencePutJSON_RefreshResendsFullBody pins the retry-safe body
// rebuild PutJSON reuses from doURL: a 401 on the first attempt (a stale
// access token) triggers the single-flight refresh, and the retried PUT
// carries the exact same JSON body as the first attempt — not an empty or
// truncated one (an already-drained reader would otherwise turn the retry
// into an effectively empty PUT).
func TestConfluencePutJSON_RefreshResendsFullBody(t *testing.T) {
	var mu sync.Mutex
	var bodies []string
	var attempt atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, string(b))
		mu.Unlock()
		if attempt.Add(1) == 1 {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"message":"token expired"}`))
			return
		}
		_, _ = w.Write([]byte(`{"id":"1"}`))
	}))
	defer srv.Close()

	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"new","refresh_token":"rt2","expires_in":3600,"scope":"s"}`))
	}))
	defer tokenSrv.Close()

	c := newTestClient(t, srv.URL, tokenSrv.URL, "stale")
	var out map[string]any
	err := c.Confluence().PutJSON(context.Background(), "/wiki/api/v2/pages/1", map[string]any{"id": "1", "version": map[string]any{"number": 2}}, &out)
	require.NoError(t, err)

	mu.Lock()
	defer mu.Unlock()
	require.Len(t, bodies, 2, "expected one 401 attempt and one retried attempt")
	assert.JSONEq(t, bodies[0], bodies[1], "the retried PUT must carry the exact same body as the first attempt")
	assert.JSONEq(t, `{"id":"1","version":{"number":2}}`, bodies[1])
}

// TestConfluencePutJSON_SuccessBodyCap pins that PutJSON's 2xx response body
// is bounded the same way GetJSON's already is.
func TestConfluencePutJSON_SuccessBodyCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		_, _ = w.Write(bytes.Repeat([]byte("a"), maxSuccessBodyBytes+1))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	var out map[string]any
	err := c.Confluence().PutJSON(context.Background(), "/wiki/api/v2/pages/1", map[string]any{"id": "1"}, &out)
	assert.ErrorIs(t, err, ErrTooLarge)
}
