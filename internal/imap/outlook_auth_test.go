package imap

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// syncBuffer is a mutex-guarded io.Writer, used where a goroutine writes
// (LoginOutlook's progress output) while the test goroutine concurrently
// reads — mirrors gmail's test helper of the same name/shape.
type syncBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// TestValidateGrantedScopes_MissingIMAPScopeRejected covers fix #10: a token
// response that DOES have a refresh_token but whose granted scope string
// omits the IMAP mailbox scope (a narrower partial grant than an empty
// refresh_token) must be rejected with a clear message telling the user to
// re-run login and approve IMAP access.
func TestValidateGrantedScopes_MissingIMAPScopeRejected(t *testing.T) {
	err := ValidateGrantedScopes("openid email offline_access")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "did not grant IMAP mailbox access")
}

// TestValidateGrantedScopes_UnknownScopeProceeds covers the defensive
// counterpart (mirrors gmail's validateGrantedScopes): the scope field is
// optional in Microsoft's token response, so an empty string means unknown,
// not denied, and must not be rejected.
func TestValidateGrantedScopes_UnknownScopeProceeds(t *testing.T) {
	require.NoError(t, ValidateGrantedScopes(""))
}

func TestValidateGrantedScopes_GrantedScopeAccepted(t *testing.T) {
	require.NoError(t, ValidateGrantedScopes(ScopeOutlookIMAP))
}

func TestNewPKCEPair_Format(t *testing.T) {
	pkce, err := newPKCEPair()
	require.NoError(t, err)

	// RFC 7636: verifier must be 43-128 chars from the unreserved charset.
	assert.GreaterOrEqual(t, len(pkce.verifier), 43)
	assert.LessOrEqual(t, len(pkce.verifier), 128)
	for _, r := range pkce.verifier {
		assert.Contains(t, pkceVerifierCharset, string(r), "verifier has a non-unreserved char")
	}

	// Challenge must be base64url (no padding) of sha256(verifier).
	assert.NotContains(t, pkce.challenge, "=")
	assert.NotContains(t, pkce.challenge, "+")
	assert.NotContains(t, pkce.challenge, "/")
	decoded, err := base64.RawURLEncoding.DecodeString(pkce.challenge)
	require.NoError(t, err)
	assert.Len(t, decoded, 32) // sha256 digest size
}

func TestNewPKCEPair_UniquePerCall(t *testing.T) {
	p1, err := newPKCEPair()
	require.NoError(t, err)
	p2, err := newPKCEPair()
	require.NoError(t, err)
	assert.NotEqual(t, p1.verifier, p2.verifier)
	assert.NotEqual(t, p1.challenge, p2.challenge)
}

func TestBuildMicrosoftAuthURL(t *testing.T) {
	cfg := MicrosoftOAuthConfig{ClientID: "client-123"}
	got := buildMicrosoftAuthURL(cfg, "http://127.0.0.1:18531/callback", "state-abc", "challenge-xyz")

	u, err := url.Parse(got)
	require.NoError(t, err)
	assert.Equal(t, "login.microsoftonline.com", u.Host)
	assert.Equal(t, "/common/oauth2/v2.0/authorize", u.Path)

	q := u.Query()
	assert.Equal(t, "client-123", q.Get("client_id"))
	assert.Equal(t, "http://127.0.0.1:18531/callback", q.Get("redirect_uri"))
	assert.Equal(t, "code", q.Get("response_type"))
	assert.Equal(t, "state-abc", q.Get("state"))
	assert.Equal(t, "challenge-xyz", q.Get("code_challenge"))
	assert.Equal(t, "S256", q.Get("code_challenge_method"))
	assert.Equal(t, ScopeOutlookIMAP, q.Get("scope"))
	// No client_secret ever — this is a PKCE public client.
	assert.Empty(t, q.Get("client_secret"))
}

func TestExchangeMicrosoftCode_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		assert.Equal(t, "authorization_code", r.PostForm.Get("grant_type"))
		assert.Equal(t, "code-123", r.PostForm.Get("code"))
		assert.Equal(t, "http://localhost/cb", r.PostForm.Get("redirect_uri"))
		assert.Equal(t, "cid", r.PostForm.Get("client_id"))
		assert.Equal(t, "verifier-abc", r.PostForm.Get("code_verifier"))
		// A PKCE public client must never send a client_secret.
		assert.Empty(t, r.PostForm.Get("client_secret"))

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"at","refresh_token":"rt","token_type":"Bearer"}`))
	}))
	defer srv.Close()

	prev := microsoftTokenEndpoint
	microsoftTokenEndpoint = srv.URL
	defer func() { microsoftTokenEndpoint = prev }()

	tok, err := exchangeMicrosoftCode(context.Background(), MicrosoftOAuthConfig{ClientID: "cid"}, "code-123", "http://localhost/cb", "verifier-abc")
	require.NoError(t, err)
	assert.Equal(t, "at", tok.AccessToken)
	assert.Equal(t, "rt", tok.RefreshToken)
}

func TestExchangeMicrosoftCode_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"invalid_grant"}`, http.StatusBadRequest)
	}))
	defer srv.Close()

	prev := microsoftTokenEndpoint
	microsoftTokenEndpoint = srv.URL
	defer func() { microsoftTokenEndpoint = prev }()

	_, err := exchangeMicrosoftCode(context.Background(), MicrosoftOAuthConfig{}, "x", "http://localhost/cb", "v")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "token request failed")
}

func TestExchangeMicrosoftCode_BadJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	}))
	defer srv.Close()

	prev := microsoftTokenEndpoint
	microsoftTokenEndpoint = srv.URL
	defer func() { microsoftTokenEndpoint = prev }()

	_, err := exchangeMicrosoftCode(context.Background(), MicrosoftOAuthConfig{}, "x", "http://localhost/cb", "v")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "decoding token response")
}

// TestRefreshAccessToken_RotatesRefreshToken covers the rotation contract:
// Microsoft may return a new refresh_token on any refresh call, and
// RefreshAccessToken must surface it (as newRefreshToken) so the caller can
// persist it — the previous refresh token may stop working otherwise.
func TestRefreshAccessToken_RotatesRefreshToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		assert.Equal(t, "refresh_token", r.PostForm.Get("grant_type"))
		assert.Equal(t, "old-rt", r.PostForm.Get("refresh_token"))
		assert.Equal(t, "cid", r.PostForm.Get("client_id"))
		assert.Empty(t, r.PostForm.Get("client_secret"))

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"new-at","refresh_token":"new-rt","token_type":"Bearer"}`))
	}))
	defer srv.Close()

	prev := microsoftTokenEndpoint
	microsoftTokenEndpoint = srv.URL
	defer func() { microsoftTokenEndpoint = prev }()

	accessToken, newRefreshToken, err := RefreshAccessToken(context.Background(), MicrosoftOAuthConfig{ClientID: "cid"}, "old-rt")
	require.NoError(t, err)
	assert.Equal(t, "new-at", accessToken)
	assert.Equal(t, "new-rt", newRefreshToken)
}

// TestRefreshAccessToken_NoRotation covers the common case where Microsoft
// doesn't rotate the refresh token — callers must tolerate an empty
// newRefreshToken and keep using the one they already have.
func TestRefreshAccessToken_NoRotation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"new-at","token_type":"Bearer"}`))
	}))
	defer srv.Close()

	prev := microsoftTokenEndpoint
	microsoftTokenEndpoint = srv.URL
	defer func() { microsoftTokenEndpoint = prev }()

	accessToken, newRefreshToken, err := RefreshAccessToken(context.Background(), MicrosoftOAuthConfig{ClientID: "cid"}, "old-rt")
	require.NoError(t, err)
	assert.Equal(t, "new-at", accessToken)
	assert.Empty(t, newRefreshToken)
}

func TestRefreshAccessToken_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"invalid_grant"}`, http.StatusBadRequest)
	}))
	defer srv.Close()

	prev := microsoftTokenEndpoint
	microsoftTokenEndpoint = srv.URL
	defer func() { microsoftTokenEndpoint = prev }()

	_, _, err := RefreshAccessToken(context.Background(), MicrosoftOAuthConfig{}, "old-rt")
	require.Error(t, err)
}

// makeIDToken builds an unsigned JWT with the given claims, matching the
// shape Microsoft's id_token has (header.payload.signature) — idTokenEmail
// only ever reads the payload segment.
func makeIDToken(t *testing.T, claims map[string]string) string {
	t.Helper()
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT"}`))
	payloadBytes, err := json.Marshal(claims)
	require.NoError(t, err)
	payload := base64.RawURLEncoding.EncodeToString(payloadBytes)
	return header + "." + payload + ".sig"
}

func TestIDTokenEmail_UsesEmailClaim(t *testing.T) {
	tok := makeIDToken(t, map[string]string{"email": "alice@outlook.com", "preferred_username": "alice2@outlook.com"})
	email, err := idTokenEmail(tok)
	require.NoError(t, err)
	assert.Equal(t, "alice@outlook.com", email)
}

func TestIDTokenEmail_FallsBackToPreferredUsername(t *testing.T) {
	tok := makeIDToken(t, map[string]string{"preferred_username": "bob@outlook.com"})
	email, err := idTokenEmail(tok)
	require.NoError(t, err)
	assert.Equal(t, "bob@outlook.com", email)
}

func TestIDTokenEmail_NoUsableClaim(t *testing.T) {
	tok := makeIDToken(t, map[string]string{"sub": "abc123"})
	_, err := idTokenEmail(tok)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "neither email nor preferred_username")
}

func TestIDTokenEmail_MalformedToken(t *testing.T) {
	_, err := idTokenEmail("not-a-jwt")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "malformed id_token")
}

func TestIDTokenEmail_BadBase64(t *testing.T) {
	_, err := idTokenEmail("header.!!!not-base64!!!.sig")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "decoding id_token payload")
}

func TestListenLocalOutlook_NotEmpty(t *testing.T) {
	ln, err := listenLocalOutlook()
	require.NoError(t, err)
	defer ln.Close()
	assert.NotEmpty(t, ln.Addr().String())
}

func TestGetOutlookOpenBrowserFunc_NotNil(t *testing.T) {
	assert.NotNil(t, getOutlookOpenBrowserFunc())
}

// TestLoginOutlook_SkipBrowserOpen_ResolvesEmail exercises the full
// LoginOutlook flow (state check, PKCE verifier round trip, callback
// handling, email resolution from the ID token) against a mocked token
// endpoint — mirrors gmail's TestLogin_SkipBrowserOpen_Success.
func TestLoginOutlook_SkipBrowserOpen_ResolvesEmail(t *testing.T) {
	idTok := makeIDToken(t, map[string]string{"email": "me@outlook.com"})

	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		assert.Equal(t, "auth-code", r.PostForm.Get("code"))
		assert.NotEmpty(t, r.PostForm.Get("code_verifier"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"at","refresh_token":"rt","token_type":"Bearer","id_token":"` + idTok + `"}`))
	}))
	defer tokenSrv.Close()

	prev := microsoftTokenEndpoint
	microsoftTokenEndpoint = tokenSrv.URL
	defer func() { microsoftTokenEndpoint = prev }()

	type result struct {
		tok   *MicrosoftOAuthToken
		email string
	}
	resCh := make(chan result, 1)
	errCh := make(chan error, 1)

	out := &syncBuffer{}
	go func() {
		tok, email, err := LoginOutlook(context.Background(), MicrosoftOAuthConfig{ClientID: "cid"}, out, OutlookLoginOptions{SkipBrowserOpen: true})
		if err != nil {
			errCh <- err
			return
		}
		resCh <- result{tok: tok, email: email}
	}()

	var authorizeURL string
	require.Eventually(t, func() bool {
		s := out.String()
		idx := strings.Index(s, "http")
		if idx == -1 {
			return false
		}
		end := strings.IndexAny(s[idx:], "\n ")
		if end == -1 {
			end = len(s) - idx
		}
		authorizeURL = s[idx : idx+end]
		return authorizeURL != ""
	}, 2*time.Second, 10*time.Millisecond)

	u, err := url.Parse(authorizeURL)
	require.NoError(t, err)
	state := u.Query().Get("state")
	redirectURI := u.Query().Get("redirect_uri")

	cbURL, err := url.Parse(redirectURI)
	require.NoError(t, err)
	q := cbURL.Query()
	q.Set("code", "auth-code")
	q.Set("state", state)
	cbURL.RawQuery = q.Encode()

	resp, err := http.Get(cbURL.String())
	require.NoError(t, err)
	defer resp.Body.Close()
	assert.Equal(t, http.StatusOK, resp.StatusCode)

	select {
	case r := <-resCh:
		assert.Equal(t, "at", r.tok.AccessToken)
		assert.Equal(t, "rt", r.tok.RefreshToken)
		assert.Equal(t, "me@outlook.com", r.email)
	case err := <-errCh:
		t.Fatalf("LoginOutlook returned error: %v", err)
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for LoginOutlook to complete")
	}
}

func TestLoginOutlook_StateMismatchRejected(t *testing.T) {
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Fatal("token endpoint must not be called on state mismatch")
	}))
	defer tokenSrv.Close()

	prev := microsoftTokenEndpoint
	microsoftTokenEndpoint = tokenSrv.URL
	defer func() { microsoftTokenEndpoint = prev }()

	errCh := make(chan error, 1)
	out := &syncBuffer{}
	go func() {
		_, _, err := LoginOutlook(context.Background(), MicrosoftOAuthConfig{ClientID: "cid"}, out, OutlookLoginOptions{SkipBrowserOpen: true})
		errCh <- err
	}()

	var authorizeURL string
	require.Eventually(t, func() bool {
		s := out.String()
		idx := strings.Index(s, "http")
		if idx == -1 {
			return false
		}
		end := strings.IndexAny(s[idx:], "\n ")
		if end == -1 {
			end = len(s) - idx
		}
		authorizeURL = s[idx : idx+end]
		return authorizeURL != ""
	}, 2*time.Second, 10*time.Millisecond)

	u, err := url.Parse(authorizeURL)
	require.NoError(t, err)
	cbURL, err := url.Parse(u.Query().Get("redirect_uri"))
	require.NoError(t, err)
	q := cbURL.Query()
	q.Set("code", "auth-code")
	q.Set("state", "wrong-state")
	cbURL.RawQuery = q.Encode()

	resp, err := http.Get(cbURL.String())
	require.NoError(t, err)
	defer resp.Body.Close()

	select {
	case err := <-errCh:
		require.Error(t, err)
		assert.Contains(t, err.Error(), "state mismatch")
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for LoginOutlook to complete")
	}
}

// --- RefreshingXOAUTH2Auth ---

// TestRefreshingXOAUTH2Auth_CallsRefreshFuncAndAuthenticates covers what the
// design doc calls out as the key point: RefreshFunc runs fresh on every
// Authenticate() call. Full IMAP-wire coverage (a real AUTHENTICATE XOAUTH2
// exchange against the in-process test server in client_test.go) isn't
// available: imapmemserver/imapserver's InsecureAuth path only wires up LOGIN,
// not SASL XOAUTH2, so there is no server-side counterpart to authenticate
// against in this repo's test harness. This test instead pins the two
// behaviors that matter at the imapclient boundary: RefreshFunc is invoked,
// and its result reaches the wire as the correct XOAUTH2 initial response
// (verified via xoauth2Client.Start(), which is what Authenticate ultimately
// drives).
func TestRefreshingXOAUTH2Auth_CallsRefreshFuncAndProducesCorrectSASLResponse(t *testing.T) {
	var calls int
	a := RefreshingXOAUTH2Auth{
		Username: "me@outlook.com",
		RefreshFunc: func(_ context.Context) (string, error) {
			calls++
			return "token-abc", nil
		},
	}

	// Exercise RefreshFunc the same way Authenticate does, then check the
	// SASL client it hands to imapclient produces the expected wire bytes —
	// Authenticate itself requires a live *imapclient.Client connection,
	// which is exactly the server-side gap noted above.
	token, err := a.RefreshFunc(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, calls)

	sasl := newXOAUTH2Client(a.Username, token)
	mech, ir, err := sasl.Start()
	require.NoError(t, err)
	assert.Equal(t, "XOAUTH2", mech)
	assert.Equal(t, "user=me@outlook.com\x01auth=Bearer token-abc\x01\x01", string(ir))

	// A second refresh must be independent (fresh token per call).
	token2, err := a.RefreshFunc(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, calls)
	assert.Equal(t, "token-abc", token2)
}

func TestRefreshingXOAUTH2Auth_RefreshErrorPropagates(t *testing.T) {
	a := RefreshingXOAUTH2Auth{
		Username: "me@outlook.com",
		RefreshFunc: func(_ context.Context) (string, error) {
			return "", assert.AnError
		},
	}
	// Authenticate needs a *imapclient.Client; nil is fine here because
	// RefreshFunc errors before that argument is ever used.
	err := a.Authenticate((*imapclient.Client)(nil))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "refreshing outlook access token")
}
