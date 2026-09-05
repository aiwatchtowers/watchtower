package jira

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuildAuthURL_IncludesScopesAndClientID(t *testing.T) {
	cfg := JiraOAuthConfig{ClientID: "atlas-app-id", ClientSecret: "shh"}
	got := buildAuthURL(cfg, "http://localhost:18511/callback", "state-xyz")

	u, err := url.Parse(got)
	require.NoError(t, err)
	assert.Equal(t, "auth.atlassian.com", u.Host)

	q := u.Query()
	assert.Equal(t, "atlas-app-id", q.Get("client_id"))
	assert.Equal(t, "http://localhost:18511/callback", q.Get("redirect_uri"))
	assert.Equal(t, "code", q.Get("response_type"))
	assert.Equal(t, "state-xyz", q.Get("state"))
	assert.Equal(t, "consent", q.Get("prompt"))
	assert.Equal(t, "api.atlassian.com", q.Get("audience"))

	scope := q.Get("scope")
	for _, s := range []string{
		"read:jira-work",
		"write:jira-work",
		"read:jira-user",
		"offline_access",
	} {
		assert.Contains(t, scope, s, "missing scope %q", s)
	}
}

func TestBuildAuthURL_EscapesScopeSpacesAsPercent20(t *testing.T) {
	got := buildAuthURL(JiraOAuthConfig{ClientID: "x"}, "http://localhost/cb", "s")
	// Atlassian rejects '+' as a scope separator; the helper rewrites it to %20.
	// Special chars (':') are URL-encoded as %3A.
	assert.NotContains(t, got, "+write")
	assert.Contains(t, got, "%20write%3Ajira-work")
}

func TestPrepare_DefaultRedirect(t *testing.T) {
	res, err := Prepare(JiraOAuthConfig{ClientID: "cid"}, "")
	require.NoError(t, err)
	assert.Contains(t, res.RedirectURI, ":18511")
	assert.Contains(t, res.AuthorizeURL, "client_id=cid")
	assert.NotEmpty(t, res.State)
}

func TestPrepare_CustomRedirect(t *testing.T) {
	res, err := Prepare(JiraOAuthConfig{ClientID: "cid"}, "http://example/cb")
	require.NoError(t, err)
	assert.Equal(t, "http://example/cb", res.RedirectURI)
}

func TestPrepare_StateIsRandom(t *testing.T) {
	r1, err := Prepare(JiraOAuthConfig{ClientID: "x"}, "")
	require.NoError(t, err)
	r2, err := Prepare(JiraOAuthConfig{ClientID: "x"}, "")
	require.NoError(t, err)
	assert.NotEqual(t, r1.State, r2.State)
}

func TestExchangeCode_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "application/json", r.Header.Get("Content-Type"))
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		require.NoError(t, json.Unmarshal(body, &payload))
		assert.Equal(t, "authorization_code", payload["grant_type"])
		assert.Equal(t, "code-abc", payload["code"])

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_in":3600,"scope":"read:jira-work"}`))
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	tok, err := exchangeCode(context.Background(), JiraOAuthConfig{ClientID: "cid", ClientSecret: "secret"}, "code-abc", "http://x/cb")
	require.NoError(t, err)
	assert.Equal(t, "at", tok.AccessToken)
	assert.Equal(t, "rt", tok.RefreshToken)
	assert.NotEmpty(t, tok.Expiry, "expiry should be calculated from expires_in")
}

func TestExchangeCode_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"invalid_grant"}`, http.StatusBadRequest)
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	_, err := exchangeCode(context.Background(), JiraOAuthConfig{}, "x", "http://x/cb")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "token exchange failed")
}

func TestExchangeCode_BadJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	_, err := exchangeCode(context.Background(), JiraOAuthConfig{}, "x", "http://x/cb")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "decoding token response")
}

func TestComplete_RejectsEmptyCode(t *testing.T) {
	_, err := Complete(context.Background(), JiraOAuthConfig{}, "", "http://x")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no authorization code")
}

func TestRefreshToken_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		require.NoError(t, json.Unmarshal(body, &payload))
		assert.Equal(t, "refresh_token", payload["grant_type"])
		assert.Equal(t, "rt-old", payload["refresh_token"])

		_, _ = w.Write([]byte(`{"access_token":"at-new","refresh_token":"rt-new","expires_in":3600}`))
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	tok, err := RefreshToken(context.Background(), JiraOAuthConfig{ClientID: "c", ClientSecret: "s"}, "rt-old")
	require.NoError(t, err)
	assert.Equal(t, "at-new", tok.AccessToken)
	assert.Equal(t, "rt-new", tok.RefreshToken)
	assert.NotEmpty(t, tok.Expiry)
}

// A non-200 that is NOT a revoked grant stays a generic failure — the caller
// must not be told to re-consent over a transient server error.
func TestRefreshToken_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"server_error"}`))
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	_, err := RefreshToken(context.Background(), JiraOAuthConfig{}, "rt")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "refresh token failed")
	assert.False(t, errors.Is(err, ErrAuthRevoked), "a server error must not read as a revoked grant")
}

// A revoked or expired refresh token reports invalid_grant, which must surface
// as ErrAuthRevoked: that is what makes Syncer.Sync abort the account's pass
// and phaseJiraSync mark the row for re-login instead of syncing nothing
// behind a green badge.
func TestRefreshToken_InvalidGrantIsAuthRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	_, err := RefreshToken(context.Background(), JiraOAuthConfig{}, "rt")
	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked))
}

// The other revoked-grant shape Atlassian returns for a dead refresh token: a
// 403 unauthorized_client whose description names the refresh token as invalid.
// It must reach the caller as ErrAuthRevoked exactly like invalid_grant, or the
// account stays green with its Re-login button hidden while every call 403s.
func TestRefreshToken_UnauthorizedClientRefreshInvalidIsAuthRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":"unauthorized_client","error_description":"refresh_token is invalid"}`))
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	_, err := RefreshToken(context.Background(), JiraOAuthConfig{}, "rt")
	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked))
}

func TestRefreshToken_BadJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{not json`))
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	_, err := RefreshToken(context.Background(), JiraOAuthConfig{}, "rt")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "decoding refresh response")
}

func TestFetchAccessibleResources_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "Bearer at-token", r.Header.Get("Authorization"))
		_, _ = w.Write([]byte(`[{"id":"site-1","url":"https://acme.atlassian.net","name":"Acme","avatarUrl":"https://x/a.png"}]`))
	}))
	defer srv.Close()

	prev := jiraAccessibleResources
	jiraAccessibleResources = srv.URL
	defer func() { jiraAccessibleResources = prev }()

	res, err := FetchAccessibleResources(context.Background(), "at-token")
	require.NoError(t, err)
	require.Len(t, res, 1)
	assert.Equal(t, "site-1", res[0].ID)
	assert.Equal(t, "Acme", res[0].Name)
	assert.Equal(t, "https://acme.atlassian.net", res[0].URL)
}

func TestFetchAccessibleResources_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
	}))
	defer srv.Close()

	prev := jiraAccessibleResources
	jiraAccessibleResources = srv.URL
	defer func() { jiraAccessibleResources = prev }()

	_, err := FetchAccessibleResources(context.Background(), "bad-token")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "accessible resources failed")
}

func TestFetchAccessibleResources_BadJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not an array`))
	}))
	defer srv.Close()

	prev := jiraAccessibleResources
	jiraAccessibleResources = srv.URL
	defer func() { jiraAccessibleResources = prev }()

	_, err := FetchAccessibleResources(context.Background(), "x")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "decoding")
}

func TestGetOpenBrowserFunc_NotNil(t *testing.T) {
	assert.NotNil(t, getOpenBrowserFunc())
}

// syncTestBuffer is a mutex-guarded buffer so the Login goroutine can write the
// authorize URL while the test reads it.
type syncTestBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (b *syncTestBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncTestBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// runLoginCaptureSuccessBody drives a full Login(opts) with a mocked token
// endpoint and browser, POSTing the OAuth callback back to the loopback server,
// and returns the HTML body served on the success page. The slack.TestLogin_
// AppReturn_SuccessPageRedirects analog on Jira's plain-HTTP loopback flow.
func runLoginCaptureSuccessBody(t *testing.T, opts LoginOptions) string {
	t.Helper()

	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"at","refresh_token":"rt","expires_in":3600}`))
	}))
	defer tokenSrv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = tokenSrv.URL
	defer func() { jiraTokenEndpoint = prev }()

	out := &syncTestBuffer{}
	opts.SkipBrowserOpen = true // print the authorize URL instead of opening a browser
	resultCh := make(chan error, 1)
	go func() {
		_, err := Login(context.Background(), JiraOAuthConfig{ClientID: "cid", ClientSecret: "s"}, out, opts)
		resultCh <- err
	}()

	var authorizeURL string
	require.Eventually(t, func() bool {
		s := out.String()
		idx := strings.Index(s, "https://")
		if idx == -1 {
			return false
		}
		end := strings.IndexAny(s[idx:], "\n ")
		if end == -1 {
			return false
		}
		authorizeURL = s[idx : idx+end]
		return authorizeURL != ""
	}, 3*time.Second, 10*time.Millisecond)

	parsed, err := url.Parse(authorizeURL)
	require.NoError(t, err)
	state := parsed.Query().Get("state")
	redirectURI := parsed.Query().Get("redirect_uri")
	require.NotEmpty(t, state)
	require.NotEmpty(t, redirectURI)

	cbURL, err := url.Parse(redirectURI)
	require.NoError(t, err)
	q := cbURL.Query()
	q.Set("code", "test-auth-code")
	q.Set("state", state)
	cbURL.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, cbURL.String(), nil)
	require.NoError(t, err)
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)

	select {
	case err := <-resultCh:
		require.NoError(t, err)
	case <-time.After(5 * time.Second):
		t.Fatal("Login did not complete in time")
	}
	return string(body)
}

// With AppReturn set, the success page must send the browser back to the app
// via the watchtower-auth:// scheme (the slack/gmail app-return precedent).
func TestLogin_AppReturn_SuccessPageRedirects(t *testing.T) {
	body := runLoginCaptureSuccessBody(t, LoginOptions{AppReturn: true})
	assert.Contains(t, body, "watchtower-auth://connected")
}

// Without it the page just self-closes and never touches the app scheme, so a
// plain browser consent is byte-for-byte the pre-feature behaviour.
func TestLogin_NoAppReturn_SuccessPageIsPlain(t *testing.T) {
	body := runLoginCaptureSuccessBody(t, LoginOptions{})
	assert.NotContains(t, body, "watchtower-auth://")
}

// Sanity-check that exchangeCode marshals payloads in JSON (not form-encoded).
func TestExchangeCode_PostsJSONBody(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		got = string(body)
		_, _ = w.Write([]byte(`{"access_token":"a"}`))
	}))
	defer srv.Close()

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	defer func() { jiraTokenEndpoint = prev }()

	_, err := exchangeCode(context.Background(), JiraOAuthConfig{ClientID: "c", ClientSecret: "s"}, "code", "http://cb")
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(got, "{"), "expected JSON body, got: %q", got)
}
