package calendar

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/auth"
	"watchtower/internal/fsutil"
	"watchtower/internal/oauthpage"
)

const (
	defaultRedirectPort = 18501 // separate range from Slack (18491-18500)
	callbackPath        = "/callback"
	loginTimeout        = 5 * time.Minute
	// ScopeCalendarReadonly is one broad read-only scope instead of
	// events.readonly + calendarlist.readonly: Google shows its
	// granular-consent checkbox screen only for MULTI-scope requests, so a
	// single scope gives a plain Continue screen the user cannot half-grant.
	// Exported for the combined `google login` flow in cmd.
	ScopeCalendarReadonly = "https://www.googleapis.com/auth/calendar.readonly"
)

// Google OAuth endpoints — vars so tests can point at httptest.Server.
var (
	googleAuthEndpoint   = "https://accounts.google.com/o/oauth2/v2/auth"
	googleTokenEndpoint  = "https://oauth2.googleapis.com/token"
	googleRevokeEndpoint = "https://oauth2.googleapis.com/revoke"
)

// DefaultGoogleClientID and DefaultGoogleClientSecret are injected at build time via -ldflags:
//
//	-X watchtower/internal/calendar.DefaultGoogleClientID=...
//	-X watchtower/internal/calendar.DefaultGoogleClientSecret=...
var (
	DefaultGoogleClientID     string
	DefaultGoogleClientSecret string
)

// GoogleOAuthConfig holds credentials for Google Calendar API.
type GoogleOAuthConfig struct {
	ClientID     string
	ClientSecret string
}

// OAuthToken represents an OAuth2 token (stored as JSON).
type OAuthToken struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	RefreshToken string `json:"refresh_token"`
	Expiry       string `json:"expiry,omitempty"`
	Scope        string `json:"scope,omitempty"`
}

// TokenStore persists and loads OAuth2 refresh/access tokens.
type TokenStore struct {
	path string // ~/.local/share/watchtower/{workspace}/google_token.json
}

// NewTokenStore creates a TokenStore for the given workspace directory.
func NewTokenStore(workspaceDir string) *TokenStore {
	return &TokenStore{
		path: filepath.Join(workspaceDir, "google_token.json"),
	}
}

// NewAccountTokenStore creates a TokenStore for the given workspace directory and account ID.
func NewAccountTokenStore(workspaceDir string, accountID int64) *TokenStore {
	return &TokenStore{
		path: filepath.Join(workspaceDir, fmt.Sprintf("google_token_%d.json", accountID)),
	}
}

// Path returns the token file path.
func (s *TokenStore) Path() string {
	return s.path
}

// Load reads the token from disk.
func (s *TokenStore) Load() (*OAuthToken, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, err
	}
	var token OAuthToken
	if err := json.Unmarshal(data, &token); err != nil {
		return nil, fmt.Errorf("parsing token: %w", err)
	}
	return &token, nil
}

// Save writes the token to disk atomically (fsutil.WriteFileAtomic).
func (s *TokenStore) Save(token *OAuthToken) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating token directory: %w", err)
	}
	data, err := json.MarshalIndent(token, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling token: %w", err)
	}
	return fsutil.WriteFileAtomic(s.path, data, 0o600)
}

// Delete removes the token file.
func (s *TokenStore) Delete() error {
	err := os.Remove(s.path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// Exists checks whether a token file is present.
func (s *TokenStore) Exists() bool {
	_, err := os.Stat(s.path)
	return err == nil
}

// LoginOptions configures the Login flow behaviour.
type LoginOptions struct {
	SkipBrowserOpen bool
	// Scopes to request; defaults to ScopeCalendarReadonly. The combined
	// `google login` flow passes the user's in-app selection here so one
	// consent screen covers exactly the chosen services.
	Scopes []string
	// AppReturn adds the "Back to Watchtower" link to the callback page
	// (oauthpage); the CLI command brings the app back itself
	// (oauthpage.ReturnAfterLogin). Off for plain CLI logins.
	AppReturn bool
}

// PrepareResult holds the data needed by the desktop app to start the OAuth flow.
type PrepareResult struct {
	AuthorizeURL string `json:"authorize_url"`
	RedirectURI  string `json:"redirect_uri"`
	State        string `json:"state"`
	// CodeVerifier is the per-login PKCE secret behind the code_challenge in
	// AuthorizeURL. Prepare and Complete are separate calls, so the caller has
	// to carry it between them and pass it back to Complete — the exchange
	// fails without it rather than falling back to a non-PKCE exchange. Keep
	// it in memory for the life of the login; never log or persist it.
	CodeVerifier string `json:"code_verifier"`
}

// Prepare generates an OAuth authorization URL for the desktop app flow.
func Prepare(cfg GoogleOAuthConfig, customRedirectURI string) (*PrepareResult, error) {
	state, err := auth.RandomState()
	if err != nil {
		return nil, fmt.Errorf("generating state: %w", err)
	}
	pkce, err := auth.NewPKCEPair()
	if err != nil {
		return nil, err
	}

	redirectURI := customRedirectURI
	if redirectURI == "" {
		redirectURI = fmt.Sprintf("http://127.0.0.1:%d%s", defaultRedirectPort, callbackPath)
	}

	authorizeURL := buildAuthURL(cfg, redirectURI, state, []string{ScopeCalendarReadonly}, pkce.Challenge)

	return &PrepareResult{
		AuthorizeURL: authorizeURL,
		RedirectURI:  redirectURI,
		State:        state,
		CodeVerifier: pkce.Verifier,
	}, nil
}

// buildAuthURL constructs the Google OAuth2 authorization URL.
func buildAuthURL(cfg GoogleOAuthConfig, redirectURI, state string, scopes []string, codeChallenge string) string {
	params := url.Values{
		"client_id":             {cfg.ClientID},
		"redirect_uri":          {redirectURI},
		"response_type":         {"code"},
		"scope":                 {strings.Join(scopes, " ")},
		"state":                 {state},
		"access_type":           {"offline"},
		"prompt":                {"consent"},
		"code_challenge":        {codeChallenge},
		"code_challenge_method": {"S256"},
	}
	return googleAuthEndpoint + "?" + params.Encode()
}

// exchangeCode exchanges an authorization code for tokens via raw HTTP POST.
// The client secret is still sent alongside the PKCE verifier: Google's
// installed-app clients expect it, so PKCE is additive here, not a
// replacement.
func exchangeCode(ctx context.Context, cfg GoogleOAuthConfig, code, redirectURI, codeVerifier string) (*OAuthToken, error) {
	if codeVerifier == "" {
		return nil, fmt.Errorf("missing PKCE code verifier: the authorization request was bound to a code_challenge, so the exchange cannot proceed without its verifier")
	}
	data := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {redirectURI},
		"client_id":     {cfg.ClientID},
		"client_secret": {cfg.ClientSecret},
		"code_verifier": {codeVerifier},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, googleTokenEndpoint, strings.NewReader(data.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	hc := &http.Client{Timeout: 30 * time.Second}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("token exchange request: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("token exchange failed (%d): %s", resp.StatusCode, body)
	}

	var token OAuthToken
	if err := json.Unmarshal(body, &token); err != nil {
		return nil, fmt.Errorf("decoding token response: %w", err)
	}
	return &token, nil
}

// GrantsScope reports whether the token's granted-scope list includes scope.
// An empty Scope field is NOT a grant: RFC 6749 §5.1 lets a server omit the
// field only when the granted scope equals the requested one, but "the user
// ticked nothing" on Google's granular-consent screen is exactly a case where
// an empty value is plausible — and access must rest on positive evidence,
// not on the absence of a denial. Google's authorization_code responses do
// carry the field, so this rejects no real grant; when it ever fires, failing
// the login loudly beats recording a service as connected and letting it
// surface later as unexplained 403s during sync.
func (t *OAuthToken) GrantsScope(scope string) bool {
	return slices.Contains(strings.Fields(t.Scope), scope)
}

// validateGrantedScopes rejects tokens that carry NONE of the requested
// scopes — Google's multi-scope checkbox screen lets the user continue
// having granted nothing, which would otherwise surface only as 403s during
// sync. A partial grant passes: the caller decides which services to enable.
func validateGrantedScopes(token *OAuthToken, requested []string) error {
	for _, s := range requested {
		if token.GrantsScope(s) {
			return nil
		}
	}
	return fmt.Errorf("google did not grant any of the requested access (granted: %q) — run login again and approve access on the consent screen", token.Scope)
}

// Complete exchanges an authorization code for tokens. codeVerifier is the
// PrepareResult.CodeVerifier of the same login; a missing or mismatched one
// is a hard failure (locally an empty-string check, at Google a rejected
// exchange) — there is no non-PKCE fallback.
func Complete(ctx context.Context, cfg GoogleOAuthConfig, code, redirectURI, codeVerifier string) (*OAuthToken, error) {
	if code == "" {
		return nil, fmt.Errorf("no authorization code provided")
	}
	return exchangeCode(ctx, cfg, code, redirectURI, codeVerifier)
}

// Revoke tells Google to revoke the grant behind the given token (refresh or
// access). Without this, logout only deletes the local file and the account
// keeps the grant — the next consent screen then says "already has some
// access" instead of listing the requested permissions.
func Revoke(ctx context.Context, token string) error {
	data := url.Values{"token": {token}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, googleRevokeEndpoint, strings.NewReader(data.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	hc := &http.Client{Timeout: 30 * time.Second}
	resp, err := hc.Do(req)
	if err != nil {
		return fmt.Errorf("revoke request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("revoke failed (%d): %s", resp.StatusCode, body)
	}
	return nil
}

// SetGoogleRevokeEndpointForTest overrides the Google token-revocation
// endpoint for the life of a test and returns a restore func. googleRevokeEndpoint
// is package-private and swapped directly by this package's own tests
// (auth_test.go); this exported seam exists for callers OUTSIDE this
// package (e.g. cmd's `google remove`) that need to exercise Revoke's real
// HTTP round trip against an httptest.Server rather than mocking Revoke
// itself.
func SetGoogleRevokeEndpointForTest(url string) (restore func()) {
	prev := googleRevokeEndpoint
	googleRevokeEndpoint = url
	return func() { googleRevokeEndpoint = prev }
}

// openBrowserFunc can be replaced in tests.
var (
	openBrowserMu   sync.Mutex
	openBrowserFunc = auth.OpenBrowser
)

func getOpenBrowserFunc() func(string) {
	openBrowserMu.Lock()
	defer openBrowserMu.Unlock()
	return openBrowserFunc
}

// Login performs the Google OAuth2 flow via a local HTTP callback server.
// Plain HTTP (not TLS) is used intentionally: Google's OAuth spec for native/loopback
// apps requires http://127.0.0.1 redirect URIs and rejects HTTPS for localhost.
// This differs from the Slack OAuth flow (internal/auth) which uses TLS.
func Login(ctx context.Context, cfg GoogleOAuthConfig, out io.Writer, opts ...LoginOptions) (*OAuthToken, error) {
	var opt LoginOptions
	if len(opts) > 0 {
		opt = opts[0]
	}

	listener, err := listenLocal()
	if err != nil {
		return nil, fmt.Errorf("starting local server: %w", err)
	}
	defer listener.Close()

	addr := listener.Addr().String()
	redirectURI := fmt.Sprintf("http://127.0.0.1:%s%s", auth.PortFromAddr(addr), callbackPath)

	state, err := auth.RandomState()
	if err != nil {
		return nil, fmt.Errorf("generating state: %w", err)
	}
	pkce, err := auth.NewPKCEPair()
	if err != nil {
		return nil, err
	}

	scopes := opt.Scopes
	if len(scopes) == 0 {
		scopes = []string{ScopeCalendarReadonly}
	}
	authorizeURL := buildAuthURL(cfg, redirectURI, state, scopes, pkce.Challenge)

	successPage := oauthpage.Success("Your Google account", opt.AppReturn)
	errorPage := func(reason string) string { return oauthpage.Error(reason, opt.AppReturn) }

	mux := http.NewServeMux()
	callback, resultCh := auth.NewCallbackHandler(state, successPage, errorPage)
	mux.HandleFunc(callbackPath, callback)

	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener)
	defer func() {
		// Brief grace period to let the browser receive and render the success/error
		// HTML page before the server is torn down.
		time.Sleep(500 * time.Millisecond)
		server.Close()
	}()

	if opt.SkipBrowserOpen {
		fmt.Fprintf(out, "Authorize URL:\n\n  %s\n\n", authorizeURL)
		fmt.Fprintf(out, "Waiting for authorization callback...\n")
	} else {
		fmt.Fprintf(out, "Opening browser for Google authorization...\n")
		fmt.Fprintf(out, "If the browser doesn't open, visit this URL:\n\n  %s\n\n", authorizeURL)
		getOpenBrowserFunc()(authorizeURL)
	}

	ctx, cancel := context.WithTimeout(ctx, loginTimeout)
	defer cancel()

	var cb auth.CallbackResult
	select {
	case cb = <-resultCh:
	case <-ctx.Done():
		return nil, fmt.Errorf("%w after %s", oauthpage.ErrLoginTimedOut, loginTimeout)
	}

	if cb.Err != "" {
		return nil, fmt.Errorf("google authorization denied: %s", cb.Err)
	}
	if cb.Code == "" {
		return nil, fmt.Errorf("no authorization code received")
	}

	token, err := exchangeCode(ctx, cfg, cb.Code, redirectURI, pkce.Verifier)
	if err != nil {
		return nil, fmt.Errorf("exchanging code for token: %w", err)
	}
	if err := validateGrantedScopes(token, scopes); err != nil {
		return nil, err
	}

	return token, nil
}

// listenLocal tries preferred ports, then falls back to a random port.
func listenLocal() (net.Listener, error) {
	preferred := []int{18501, 18502, 18503, 18504, 18505, 18506, 18507, 18508, 18509, 18510}
	for _, port := range preferred {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			return ln, nil
		}
	}
	return net.Listen("tcp", "127.0.0.1:0")
}
