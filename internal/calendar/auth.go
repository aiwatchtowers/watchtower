package calendar

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
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

// Save writes the token to disk.
func (s *TokenStore) Save(token *OAuthToken) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating token directory: %w", err)
	}
	data, err := json.MarshalIndent(token, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling token: %w", err)
	}
	return os.WriteFile(s.path, data, 0o600)
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
	// AppReturn makes the success page redirect the browser to the
	// watchtower-auth:// scheme, so macOS brings the desktop app back to the
	// foreground after the consent flow. Off for plain CLI logins.
	AppReturn bool
}

// PrepareResult holds the data needed by the desktop app to start the OAuth flow.
type PrepareResult struct {
	AuthorizeURL string `json:"authorize_url"`
	RedirectURI  string `json:"redirect_uri"`
	State        string `json:"state"`
}

// Prepare generates an OAuth authorization URL for the desktop app flow.
func Prepare(cfg GoogleOAuthConfig, customRedirectURI string) (*PrepareResult, error) {
	state, err := auth.RandomState()
	if err != nil {
		return nil, fmt.Errorf("generating state: %w", err)
	}

	redirectURI := customRedirectURI
	if redirectURI == "" {
		redirectURI = fmt.Sprintf("http://127.0.0.1:%d%s", defaultRedirectPort, callbackPath)
	}

	authorizeURL := buildAuthURL(cfg, redirectURI, state, []string{ScopeCalendarReadonly})

	return &PrepareResult{
		AuthorizeURL: authorizeURL,
		RedirectURI:  redirectURI,
		State:        state,
	}, nil
}

// buildAuthURL constructs the Google OAuth2 authorization URL.
func buildAuthURL(cfg GoogleOAuthConfig, redirectURI, state string, scopes []string) string {
	params := url.Values{
		"client_id":     {cfg.ClientID},
		"redirect_uri":  {redirectURI},
		"response_type": {"code"},
		"scope":         {strings.Join(scopes, " ")},
		"state":         {state},
		"access_type":   {"offline"},
		"prompt":        {"consent"},
	}
	return googleAuthEndpoint + "?" + params.Encode()
}

// exchangeCode exchanges an authorization code for tokens via raw HTTP POST.
func exchangeCode(ctx context.Context, cfg GoogleOAuthConfig, code, redirectURI string) (*OAuthToken, error) {
	data := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {redirectURI},
		"client_id":     {cfg.ClientID},
		"client_secret": {cfg.ClientSecret},
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
// An empty Scope field means the response didn't say — treated as granted,
// since Google omits it only in legacy/test responses, never to deny.
func (t *OAuthToken) GrantsScope(scope string) bool {
	if t.Scope == "" {
		return true
	}
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

// Complete exchanges an authorization code for tokens.
func Complete(ctx context.Context, cfg GoogleOAuthConfig, code, redirectURI string) (*OAuthToken, error) {
	if code == "" {
		return nil, fmt.Errorf("no authorization code provided")
	}
	return exchangeCode(ctx, cfg, code, redirectURI)
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

// callbackResult is sent from the HTTP callback handler to the Login goroutine.
type callbackResult struct {
	code  string
	state string
	err   string
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

	scopes := opt.Scopes
	if len(scopes) == 0 {
		scopes = []string{ScopeCalendarReadonly}
	}
	authorizeURL := buildAuthURL(cfg, redirectURI, state, scopes)

	resultCh := make(chan callbackResult, 1)

	// With app-return the page first sits for 3s (so the confirmation is
	// readable and the redirect doesn't race page load, which spawns a blank
	// tab in some browsers), then navigates to the app scheme; the tab tries
	// to close itself only after that. Without app-return it just self-closes.
	returnBlock, closeMS := "", "2000"
	if opt.AppReturn {
		returnBlock = appReturnBlock
		closeMS = "4500"
	}
	successPage := strings.NewReplacer("<!--RETURN-->", returnBlock, "{{CLOSE_MS}}", closeMS).
		Replace(callbackSuccessPage)

	mux := http.NewServeMux()
	mux.HandleFunc(callbackPath, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if errMsg := q.Get("error"); errMsg != "" {
			resultCh <- callbackResult{err: errMsg}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, strings.Replace(callbackErrorPage, "{{ERROR}}", html.EscapeString(errMsg), 1))
			return
		}
		resultCh <- callbackResult{
			code:  q.Get("code"),
			state: q.Get("state"),
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, successPage)
	})

	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener) //nolint:errcheck
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

	var cb callbackResult
	select {
	case cb = <-resultCh:
	case <-ctx.Done():
		return nil, fmt.Errorf("login timed out after %s", loginTimeout)
	}

	if cb.err != "" {
		return nil, fmt.Errorf("google authorization denied: %s", cb.err)
	}
	if cb.state != state {
		return nil, fmt.Errorf("state mismatch: possible CSRF attack")
	}
	if cb.code == "" {
		return nil, fmt.Errorf("no authorization code received")
	}

	token, err := exchangeCode(ctx, cfg, cb.code, redirectURI)
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

const callbackSuccessPage = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Watchtower — Google Connected</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#0f0f0f;color:#e5e5e5}
.card{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:16px;padding:48px;max-width:440px;text-align:center}
.logo{width:52px;height:52px;border-radius:13px;background:linear-gradient(135deg,#5b8cff,#3f5be0);color:#fff;font-weight:700;font-size:24px;line-height:52px;margin:0 auto 18px}
h1{font-size:20px;margin-bottom:8px}p{color:#888;font-size:14px}
.btn{display:inline-block;margin-top:22px;padding:13px 32px;background:linear-gradient(135deg,#5b8cff,#3f5be0);color:#fff;text-decoration:none;font-weight:600;font-size:15px;border-radius:10px;box-shadow:0 4px 14px rgba(63,91,224,.35)}
.btn:hover{filter:brightness(1.12)}
.hint{margin-top:12px;color:#666;font-size:12px}</style></head>
<body><div class="card"><div class="logo">W</div><h1>Google Connected</h1><p>Your Google account has been linked to Watchtower.</p><!--RETURN--></div>
<script>setTimeout(function(){try{window.close()}catch(e){}},{{CLOSE_MS}});</script></body></html>`

// appReturnBlock is injected into the success page when LoginOptions.AppReturn
// is set. The button is the reliable path back to the app — browsers block
// scripted navigation to custom schemes without a user gesture, so the
// delayed auto-redirect below is best-effort only.
const appReturnBlock = `<a class="btn" href="watchtower-auth://connected">Open Watchtower</a>
<p class="hint">You can close this tab afterwards.</p>
<script>setTimeout(function(){location.href="watchtower-auth://connected";},3000);</script>`

const callbackErrorPage = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Watchtower — Error</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#0f0f0f;color:#e5e5e5}
.card{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:16px;padding:48px;max-width:440px;text-align:center}
h1{font-size:20px;margin-bottom:8px}p{color:#888;font-size:14px}</style></head>
<body><div class="card"><h1>Authorization Failed</h1><p>{{ERROR}}</p></div></body></html>`
