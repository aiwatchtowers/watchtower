package calendar

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTokenStore_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir)

	assert.False(t, store.Exists(), "fresh dir should have no token")
	assert.Equal(t, filepath.Join(dir, "google_token.json"), store.Path())

	tok := &OAuthToken{
		AccessToken:  "ya29.a0",
		TokenType:    "Bearer",
		RefreshToken: "1//rt",
		Expiry:       "2026-04-02T12:00:00Z",
	}
	require.NoError(t, store.Save(tok))
	assert.True(t, store.Exists())

	// File mode must be 0600 (secret).
	info, err := os.Stat(store.Path())
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	loaded, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, tok.AccessToken, loaded.AccessToken)
	assert.Equal(t, tok.RefreshToken, loaded.RefreshToken)
	assert.Equal(t, tok.Expiry, loaded.Expiry)

	require.NoError(t, store.Delete())
	assert.False(t, store.Exists())

	// Delete on a missing file is idempotent.
	require.NoError(t, store.Delete())
}

func TestTokenStore_LoadCorrupt(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir)

	require.NoError(t, os.WriteFile(store.Path(), []byte("not json"), 0o600))

	_, err := store.Load()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "parsing token")
}

func TestTokenStore_LoadMissing(t *testing.T) {
	store := NewTokenStore(t.TempDir())
	_, err := store.Load()
	require.Error(t, err)
}

func TestBuildAuthURL(t *testing.T) {
	cfg := GoogleOAuthConfig{ClientID: "client.apps", ClientSecret: "shh"}
	got := buildAuthURL(cfg, "http://127.0.0.1:18501/callback", "state-abc")

	u, err := url.Parse(got)
	require.NoError(t, err)
	assert.Equal(t, "accounts.google.com", u.Host)

	q := u.Query()
	assert.Equal(t, "client.apps", q.Get("client_id"))
	assert.Equal(t, "http://127.0.0.1:18501/callback", q.Get("redirect_uri"))
	assert.Equal(t, "code", q.Get("response_type"))
	assert.Equal(t, "state-abc", q.Get("state"))
	assert.Equal(t, "offline", q.Get("access_type"))
	assert.Equal(t, "consent", q.Get("prompt"))
	scope := q.Get("scope")
	assert.Contains(t, scope, "calendar.events.readonly")
	assert.Contains(t, scope, "calendar.calendarlist.readonly")
}

func TestPrepare_DefaultRedirect(t *testing.T) {
	cfg := GoogleOAuthConfig{ClientID: "cid", ClientSecret: "cs"}
	res, err := Prepare(cfg, "")
	require.NoError(t, err)

	assert.Contains(t, res.RedirectURI, "127.0.0.1:18501")
	assert.NotEmpty(t, res.State)
	assert.Contains(t, res.AuthorizeURL, "client_id=cid")
	assert.Contains(t, res.AuthorizeURL, url.QueryEscape(res.RedirectURI))
}

func TestPrepare_CustomRedirect(t *testing.T) {
	cfg := GoogleOAuthConfig{ClientID: "cid"}
	res, err := Prepare(cfg, "http://example.com/cb")
	require.NoError(t, err)

	assert.Equal(t, "http://example.com/cb", res.RedirectURI)
	assert.Contains(t, res.AuthorizeURL, url.QueryEscape("http://example.com/cb"))
}

func TestPrepare_GeneratesUniqueState(t *testing.T) {
	r1, err := Prepare(GoogleOAuthConfig{ClientID: "x"}, "")
	require.NoError(t, err)
	r2, err := Prepare(GoogleOAuthConfig{ClientID: "x"}, "")
	require.NoError(t, err)

	assert.NotEqual(t, r1.State, r2.State, "state must be unique per call")
}

func TestExchangeCode_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		assert.Equal(t, "authorization_code", r.PostForm.Get("grant_type"))
		assert.Equal(t, "code-123", r.PostForm.Get("code"))
		assert.Equal(t, "http://localhost/cb", r.PostForm.Get("redirect_uri"))
		assert.Equal(t, "cid", r.PostForm.Get("client_id"))
		assert.Equal(t, "secret", r.PostForm.Get("client_secret"))

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"at","refresh_token":"rt","token_type":"Bearer"}`))
	}))
	defer srv.Close()

	prev := googleTokenEndpoint
	googleTokenEndpoint = srv.URL
	defer func() { googleTokenEndpoint = prev }()

	tok, err := exchangeCode(context.Background(), GoogleOAuthConfig{ClientID: "cid", ClientSecret: "secret"}, "code-123", "http://localhost/cb")
	require.NoError(t, err)
	assert.Equal(t, "at", tok.AccessToken)
	assert.Equal(t, "rt", tok.RefreshToken)
}

func TestExchangeCode_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"invalid_grant"}`, http.StatusBadRequest)
	}))
	defer srv.Close()

	prev := googleTokenEndpoint
	googleTokenEndpoint = srv.URL
	defer func() { googleTokenEndpoint = prev }()

	_, err := exchangeCode(context.Background(), GoogleOAuthConfig{}, "x", "http://localhost/cb")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "token exchange failed")
}

func TestExchangeCode_BadJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	}))
	defer srv.Close()

	prev := googleTokenEndpoint
	googleTokenEndpoint = srv.URL
	defer func() { googleTokenEndpoint = prev }()

	_, err := exchangeCode(context.Background(), GoogleOAuthConfig{}, "x", "http://localhost/cb")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "decoding token response")
}

func TestComplete_RejectsEmptyCode(t *testing.T) {
	_, err := Complete(context.Background(), GoogleOAuthConfig{}, "", "http://x")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no authorization code")
}

func TestNewClient_RefreshOK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		assert.Equal(t, "refresh_token", r.PostForm.Get("grant_type"))
		assert.Equal(t, "rt-abc", r.PostForm.Get("refresh_token"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"new-at"}`))
	}))
	defer srv.Close()

	prev := googleTokenEndpoint
	googleTokenEndpoint = srv.URL
	defer func() { googleTokenEndpoint = prev }()

	client, err := NewClient(context.Background(), "rt-abc", GoogleOAuthConfig{ClientID: "c", ClientSecret: "s"})
	require.NoError(t, err)
	assert.Equal(t, "new-at", client.accessToken)
}

func TestNewClient_RefreshRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_grant","error_description":"Token has been expired or revoked."}`))
	}))
	defer srv.Close()

	prev := googleTokenEndpoint
	googleTokenEndpoint = srv.URL
	defer func() { googleTokenEndpoint = prev }()

	_, err := NewClient(context.Background(), "rt", GoogleOAuthConfig{})
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrAuthRevoked)
}

func TestNewClient_RefreshGenericError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`oops`))
	}))
	defer srv.Close()

	prev := googleTokenEndpoint
	googleTokenEndpoint = srv.URL
	defer func() { googleTokenEndpoint = prev }()

	_, err := NewClient(context.Background(), "rt", GoogleOAuthConfig{})
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrAuthRevoked)
	assert.Contains(t, err.Error(), "token refresh failed")
}

func TestClient_DoGet_RetriesOn401(t *testing.T) {
	var calls int
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			// First call returns 401 — client should refresh and retry.
			assert.Equal(t, "Bearer first-at", r.Header.Get("Authorization"))
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		assert.Equal(t, "Bearer refreshed-at", r.Header.Get("Authorization"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"items":[]}`))
	}))
	defer apiSrv.Close()

	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"refreshed-at"}`))
	}))
	defer tokenSrv.Close()

	prevAPI, prevToken := calendarAPIBase, googleTokenEndpoint
	calendarAPIBase, googleTokenEndpoint = apiSrv.URL, tokenSrv.URL
	defer func() { calendarAPIBase, googleTokenEndpoint = prevAPI, prevToken }()

	c := &Client{
		hc:           apiSrv.Client(),
		accessToken:  "first-at",
		refreshToken: "rt",
		oauthCfg:     GoogleOAuthConfig{},
	}
	body, err := c.doGet(context.Background(), "/calendars/primary/events", nil)
	require.NoError(t, err)
	assert.Contains(t, string(body), "items")
	assert.Equal(t, 2, calls)
}

func TestClient_DoGet_ErrorAfterRetry(t *testing.T) {
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer apiSrv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"x"}`))
	}))
	defer tokenSrv.Close()

	prevAPI, prevToken := calendarAPIBase, googleTokenEndpoint
	calendarAPIBase, googleTokenEndpoint = apiSrv.URL, tokenSrv.URL
	defer func() { calendarAPIBase, googleTokenEndpoint = prevAPI, prevToken }()

	c := &Client{hc: apiSrv.Client(), accessToken: "x", refreshToken: "rt"}
	_, err := c.doGet(context.Background(), "/x", nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "API error")
}

func TestClient_DoGet_NonOK(t *testing.T) {
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`forbidden`))
	}))
	defer apiSrv.Close()
	prev := calendarAPIBase
	calendarAPIBase = apiSrv.URL
	defer func() { calendarAPIBase = prev }()

	c := &Client{hc: apiSrv.Client(), accessToken: "x"}
	_, err := c.doGet(context.Background(), "/x", nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "API error (403)")
}

func TestClient_FetchEvents_Pagination(t *testing.T) {
	pages := []string{
		`{"items":[{"id":"e1","status":"confirmed","summary":"A","start":{"dateTime":"2026-04-02T09:00:00Z"},"end":{"dateTime":"2026-04-02T10:00:00Z"}}],"nextPageToken":"tok"}`,
		`{"items":[{"id":"e2","status":"cancelled","summary":"B"},{"id":"e3","status":"confirmed","summary":"C","start":{"dateTime":"2026-04-02T11:00:00Z"},"end":{"dateTime":"2026-04-02T12:00:00Z"}}]}`,
	}
	var n int
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "Bearer at", r.Header.Get("Authorization"))
		q := r.URL.Query()
		assert.Equal(t, "true", q.Get("singleEvents"))
		assert.Equal(t, "startTime", q.Get("orderBy"))
		if n > 0 {
			assert.Equal(t, "tok", q.Get("pageToken"))
		}
		idx := n
		if idx >= len(pages) {
			idx = len(pages) - 1
		}
		_, _ = w.Write([]byte(pages[idx]))
		n++
	}))
	defer apiSrv.Close()

	prev := calendarAPIBase
	calendarAPIBase = apiSrv.URL
	defer func() { calendarAPIBase = prev }()

	c := &Client{hc: apiSrv.Client(), accessToken: "at"}
	timeMin, timeMax := mustTime("2026-04-02T00:00:00Z"), mustTime("2026-04-03T00:00:00Z")
	events, err := c.FetchEvents(context.Background(), []string{"primary"}, timeMin, timeMax)
	require.NoError(t, err)

	// Cancelled event must be filtered out, leaving 2.
	require.Len(t, events, 2)
	assert.Equal(t, "e1", events[0].ID)
	assert.Equal(t, "e3", events[1].ID)
	assert.Equal(t, 2, n, "two API calls expected (initial + page)")
}

func TestClient_FetchEvents_DefaultsToPrimary(t *testing.T) {
	var capturedPath string
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		_, _ = w.Write([]byte(`{"items":[]}`))
	}))
	defer apiSrv.Close()
	prev := calendarAPIBase
	calendarAPIBase = apiSrv.URL
	defer func() { calendarAPIBase = prev }()

	c := &Client{hc: apiSrv.Client(), accessToken: "at"}
	_, err := c.FetchEvents(context.Background(), nil, mustTime("2026-04-02T00:00:00Z"), mustTime("2026-04-03T00:00:00Z"))
	require.NoError(t, err)
	assert.Contains(t, capturedPath, "/primary/events")
}

func TestClient_FetchCalendars_Success(t *testing.T) {
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/users/me/calendarList", r.URL.Path)
		_, _ = w.Write([]byte(`{"items":[{"id":"primary","summary":"Main","primary":true,"backgroundColor":"#fff"},{"id":"work","summary":"Work","backgroundColor":"#000"}]}`))
	}))
	defer apiSrv.Close()
	prev := calendarAPIBase
	calendarAPIBase = apiSrv.URL
	defer func() { calendarAPIBase = prev }()

	c := &Client{hc: apiSrv.Client(), accessToken: "at"}
	cals, err := c.FetchCalendars(context.Background())
	require.NoError(t, err)
	require.Len(t, cals, 2)
	assert.Equal(t, "primary", cals[0].ID)
	assert.True(t, cals[0].Primary)
	assert.Equal(t, "Main", cals[0].Summary)
	assert.Equal(t, "#fff", cals[0].Color)
}

func TestClient_FetchCalendars_BadJSON(t *testing.T) {
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	}))
	defer apiSrv.Close()
	prev := calendarAPIBase
	calendarAPIBase = apiSrv.URL
	defer func() { calendarAPIBase = prev }()

	c := &Client{hc: apiSrv.Client(), accessToken: "at"}
	_, err := c.FetchCalendars(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "decoding calendar list")
}

func TestListenLocal_NotEmpty(t *testing.T) {
	ln, err := listenLocal()
	require.NoError(t, err)
	defer ln.Close()
	assert.NotEmpty(t, ln.Addr().String())
}

func TestGetOpenBrowserFunc_NotNil(t *testing.T) {
	assert.NotNil(t, getOpenBrowserFunc())
}

// Ensure the OAuthToken JSON shape is stable so saved tokens stay loadable.
func TestOAuthToken_JSONShape(t *testing.T) {
	tok := OAuthToken{AccessToken: "a", TokenType: "Bearer", RefreshToken: "r", Expiry: "e"}
	data, err := json.Marshal(tok)
	require.NoError(t, err)
	s := string(data)
	for _, key := range []string{"access_token", "token_type", "refresh_token", "expiry"} {
		assert.True(t, strings.Contains(s, `"`+key+`"`), "missing key %s in %s", key, s)
	}
}

// mustTime parses an RFC3339 timestamp or fails the test setup at compile time.
func mustTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}
