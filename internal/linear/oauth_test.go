package linear

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func setOpenBrowser(t *testing.T, f func(string)) {
	t.Helper()
	openBrowserMu.Lock()
	old := openBrowserFunc
	openBrowserFunc = f
	openBrowserMu.Unlock()
	t.Cleanup(func() {
		openBrowserMu.Lock()
		openBrowserFunc = old
		openBrowserMu.Unlock()
	})
}

func TestAuthorizeURL_PKCEAndScopes(t *testing.T) {
	u, err := url.Parse(authorizeURL(OAuthConfig{ClientID: "cid"}, "http://localhost:18531/callback", "st", "chal"))
	require.NoError(t, err)
	q := u.Query()
	assert.Equal(t, "cid", q.Get("client_id"))
	assert.Equal(t, "code", q.Get("response_type"))
	assert.Equal(t, Scopes, q.Get("scope"))
	assert.Equal(t, "S256", q.Get("code_challenge_method"))
	assert.Equal(t, "chal", q.Get("code_challenge"))
	assert.Equal(t, "user", q.Get("actor"))
	assert.Equal(t, "st", q.Get("state"))
}

func TestExchangeCode_SendsVerifierNoSecret(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		assert.Equal(t, "authorization_code", r.PostForm.Get("grant_type"))
		assert.Equal(t, "ver", r.PostForm.Get("code_verifier"))
		assert.Empty(t, r.PostForm.Get("client_secret"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399,"token_type":"Bearer"}`))
	}))
	t.Cleanup(srv.Close)
	tok, err := exchangeCode(context.Background(), OAuthConfig{ClientID: "cid"}, "code", "ver", "http://localhost:18531/callback", srv.URL)
	require.NoError(t, err)
	assert.Equal(t, "r1", tok.RefreshToken)
	assert.False(t, tok.IsExpired())
}

func TestRefreshToken_InvalidGrantIsRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
	}))
	t.Cleanup(srv.Close)
	_, err := refreshToken(context.Background(), OAuthConfig{ClientID: "cid"}, "r1", srv.URL)
	assert.ErrorIs(t, err, ErrAuthRevoked)
}

func TestRefreshToken_ServerErrorIsNotRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	t.Cleanup(srv.Close)
	_, err := refreshToken(context.Background(), OAuthConfig{ClientID: "cid"}, "r1", srv.URL)
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrAuthRevoked)
}

func TestRefreshToken_KeepsOldRefreshWhenOmitted(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"a2","expires_in":3600}`))
	}))
	t.Cleanup(srv.Close)
	tok, err := refreshToken(context.Background(), OAuthConfig{ClientID: "cid"}, "r1", srv.URL)
	require.NoError(t, err)
	assert.Equal(t, "r1", tok.RefreshToken)
}

func TestRevoke_StatusHandling(t *testing.T) {
	for code, wantErr := range map[int]bool{200: false, 400: false, 500: true} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			require.NoError(t, r.ParseForm())
			assert.Equal(t, "tok", r.PostForm.Get("token"))
			w.WriteHeader(code)
		}))
		old := revokeEndpoint
		revokeEndpoint = srv.URL
		err := Revoke(context.Background(), "tok")
		revokeEndpoint = old
		srv.Close()
		assert.Equal(t, wantErr, err != nil, "status %d", code)
	}
}

func TestTokenStore_RoundTripAndExpiry(t *testing.T) {
	s := NewTokenStore(t.TempDir(), 3)
	assert.True(t, strings.HasSuffix(s.path, "linear_token_3.json"))
	require.NoError(t, s.Save(&Token{AccessToken: "a", RefreshToken: "r", Expiry: time.Now().Add(time.Hour).Format(time.RFC3339)}))
	assert.True(t, s.Exists())
	got, err := s.Load()
	require.NoError(t, err)
	assert.False(t, got.IsExpired())
	assert.True(t, (&Token{}).IsExpired())
	require.NoError(t, s.Delete())
	require.NoError(t, s.Delete()) // idempotent
}

func TestLogin_FullLoopbackFlow(t *testing.T) {
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	}))
	t.Cleanup(tokenSrv.Close)
	old := tokenEndpoint
	tokenEndpoint = tokenSrv.URL
	t.Cleanup(func() { tokenEndpoint = old })
	setOpenBrowser(t, func(raw string) {
		u, _ := url.Parse(raw)
		cb := u.Query().Get("redirect_uri") + "?code=c1&state=" + u.Query().Get("state")
		go func() {
			resp, err := http.Get(cb) //nolint:noctx,gosec // loopback URL built by the test
			if err == nil {
				resp.Body.Close()
			}
		}()
	})
	tok, err := Login(context.Background(), OAuthConfig{ClientID: "cid"}, &strings.Builder{}, LoginOptions{})
	require.NoError(t, err)
	assert.Equal(t, "a1", tok.AccessToken)
}
