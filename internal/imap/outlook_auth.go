package imap

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/emersion/go-imap/v2/imapclient"

	"watchtower/internal/auth"
)

const (
	outlookCallbackPath = "/callback"
	outlookLoginTimeout = 5 * time.Minute

	// scopeOutlookIMAPMail is the specific scope (bundled inside
	// ScopeOutlookIMAP alongside openid/email/offline_access) that grants
	// mailbox access — the one ValidateGrantedScopes confirms was actually
	// granted, not just requested.
	scopeOutlookIMAPMail = "https://outlook.office.com/IMAP.AccessAsUser.All"

	// ScopeOutlookIMAP requests offline access (for a refresh token) plus IMAP
	// access to the mailbox. openid+email let Login resolve the connected
	// account's address out of the returned ID token — see idTokenEmail.
	ScopeOutlookIMAP = "openid email offline_access " + scopeOutlookIMAPMail
)

// ValidateGrantedScopes rejects a token whose granted scope string is present
// but omits the IMAP mailbox scope — a narrower partial-grant case than an
// entirely missing refresh_token (see cmd/outlook.go's runOutlookLogin, which
// checks both). Mirrors gmail.validateGrantedScopes: the scope field is
// optional in Microsoft's token response, so an empty string means unknown,
// not denied, and is not rejected here.
func ValidateGrantedScopes(granted string) error {
	if granted == "" {
		return nil
	}
	if !slices.Contains(strings.Fields(granted), scopeOutlookIMAPMail) {
		return fmt.Errorf("microsoft did not grant IMAP mailbox access (missing scope: %s) — run login again and approve IMAP access on the consent screen", scopeOutlookIMAPMail)
	}
	return nil
}

// Microsoft identity platform OAuth endpoints (the "common" tenant accepts
// both personal Outlook.com/Hotmail accounts and work/school Office365
// accounts) — vars so tests can point at httptest.Server.
var (
	microsoftAuthEndpoint  = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
	microsoftTokenEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
)

// DefaultMicrosoftClientID is injected at build time via -ldflags (see
// scripts/build-app.sh), mirroring calendar.DefaultGoogleClientID /
// jira.DefaultJiraClientID. Empty in dev builds; callers may also override it
// via an env var (see cmd.resolveMicrosoftOAuthConfig).
var DefaultMicrosoftClientID string

// MicrosoftOAuthConfig holds credentials for the Outlook/Office365 IMAP
// integration. Unlike Google/Jira, this is a PKCE public client — there is no
// client secret, since embedding one in a shipped desktop binary provides no
// real confidentiality; PKCE (RFC 7636) is Microsoft's recommended pattern
// for native/desktop apps instead.
type MicrosoftOAuthConfig struct {
	ClientID string
}

// MicrosoftOAuthToken represents the Microsoft identity platform's token
// response (stored as JSON, same shape convention as gmail.OAuthToken).
type MicrosoftOAuthToken struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token,omitempty"`
	ExpiresIn    int    `json:"expires_in,omitempty"`
	Scope        string `json:"scope,omitempty"`
}

// pkcePair is one code_verifier/code_challenge pair for one login attempt.
type pkcePair struct {
	verifier  string
	challenge string
}

// pkceVerifierCharset is the RFC 7636 "unreserved" character set allowed in a
// code_verifier.
const pkceVerifierCharset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

// pkceVerifierLen is comfortably within RFC 7636's required 43-128 chars.
const pkceVerifierLen = 64

// newPKCEPair generates a fresh RFC 7636 code_verifier (43-128 chars from the
// unreserved charset) and its S256 code_challenge.
func newPKCEPair() (pkcePair, error) {
	buf := make([]byte, pkceVerifierLen)
	if _, err := rand.Read(buf); err != nil {
		return pkcePair{}, fmt.Errorf("generating pkce verifier: %w", err)
	}
	verifier := make([]byte, pkceVerifierLen)
	for i, b := range buf {
		verifier[i] = pkceVerifierCharset[int(b)%len(pkceVerifierCharset)]
	}
	sum := sha256.Sum256(verifier)
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	return pkcePair{verifier: string(verifier), challenge: challenge}, nil
}

// buildMicrosoftAuthURL constructs the Microsoft identity platform
// authorization URL for a PKCE public client (no client_secret).
func buildMicrosoftAuthURL(cfg MicrosoftOAuthConfig, redirectURI, state, codeChallenge string) string {
	params := url.Values{
		"client_id":             {cfg.ClientID},
		"redirect_uri":          {redirectURI},
		"response_type":         {"code"},
		"scope":                 {ScopeOutlookIMAP},
		"state":                 {state},
		"code_challenge":        {codeChallenge},
		"code_challenge_method": {"S256"},
		"response_mode":         {"query"},
	}
	return microsoftAuthEndpoint + "?" + params.Encode()
}

// exchangeMicrosoftCode exchanges an authorization code for tokens via raw
// HTTP POST, sending the PKCE verifier instead of a client_secret.
func exchangeMicrosoftCode(ctx context.Context, cfg MicrosoftOAuthConfig, code, redirectURI, codeVerifier string) (*MicrosoftOAuthToken, error) {
	data := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {redirectURI},
		"client_id":     {cfg.ClientID},
		"code_verifier": {codeVerifier},
	}
	return postMicrosoftToken(ctx, data)
}

// RefreshAccessToken exchanges a refresh token for a new access token.
// Microsoft may rotate the refresh token on each use — callers MUST persist
// the returned refresh token whenever it is non-empty and different from the
// one they sent, or the previous refresh token may stop working.
func RefreshAccessToken(ctx context.Context, cfg MicrosoftOAuthConfig, refreshToken string) (accessToken, newRefreshToken string, err error) {
	data := url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {refreshToken},
		"client_id":     {cfg.ClientID},
		"scope":         {ScopeOutlookIMAP},
	}
	token, err := postMicrosoftToken(ctx, data)
	if err != nil {
		return "", "", err
	}
	return token.AccessToken, token.RefreshToken, nil
}

func postMicrosoftToken(ctx context.Context, data url.Values) (*MicrosoftOAuthToken, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, microsoftTokenEndpoint, strings.NewReader(data.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	hc := &http.Client{Timeout: 30 * time.Second}
	// #nosec G704 -- the request URL is microsoftTokenEndpoint, a package
	// constant overridable only by tests (httptest.Server); no caller input
	// reaches it, so this isn't an SSRF sink despite the taint analysis.
	resp, err := hc.Do(req) //nolint:gosec
	if err != nil {
		return nil, fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("token request failed (%d): %s", resp.StatusCode, body)
	}

	var token MicrosoftOAuthToken
	if err := json.Unmarshal(body, &token); err != nil {
		return nil, fmt.Errorf("decoding token response: %w", err)
	}
	return &token, nil
}

// idTokenClaims is the subset of ID token JWT claims this package reads.
type idTokenClaims struct {
	Email             string `json:"email"`
	PreferredUsername string `json:"preferred_username"`
}

// idTokenEmail extracts the account's email address from an OpenID Connect ID
// token by base64url-decoding its JWT payload segment. No signature
// verification is performed: the token was obtained via a direct HTTPS call
// to Microsoft's own token endpoint (not passed through the browser or any
// other untrusted party), so the same trust already placed in that HTTPS
// connection covers this claims read — there is no separate party whose
// forgery a signature check would need to catch.
func idTokenEmail(idToken string) (string, error) {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return "", fmt.Errorf("malformed id_token: expected 3 segments, got %d", len(parts))
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", fmt.Errorf("decoding id_token payload: %w", err)
	}
	var claims idTokenClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", fmt.Errorf("parsing id_token claims: %w", err)
	}
	if claims.Email != "" {
		return claims.Email, nil
	}
	if claims.PreferredUsername != "" {
		return claims.PreferredUsername, nil
	}
	return "", fmt.Errorf("id_token has neither email nor preferred_username claim")
}

// outlookCallbackResult is sent from the HTTP callback handler to the Login goroutine.
type outlookCallbackResult struct {
	code  string
	state string
	err   string
}

// outlookOpenBrowserFunc can be replaced in tests.
var (
	outlookOpenBrowserMu   sync.Mutex
	outlookOpenBrowserFunc = auth.OpenBrowser
)

func getOutlookOpenBrowserFunc() func(string) {
	outlookOpenBrowserMu.Lock()
	defer outlookOpenBrowserMu.Unlock()
	return outlookOpenBrowserFunc
}

// OutlookLoginOptions configures the LoginOutlook flow behaviour, mirroring
// gmail.LoginOptions.
type OutlookLoginOptions struct {
	SkipBrowserOpen bool
	// AppReturn makes the success page redirect the browser to the
	// watchtower-auth:// scheme — see gmail.LoginOptions.AppReturn.
	AppReturn bool
}

// LoginOutlook performs the Microsoft OAuth2 (PKCE) flow via a local HTTP
// callback server, mirroring gmail.Login. On success it also resolves the
// connected account's email address from the ID token so the caller doesn't
// need a separate profile-fetch round trip.
func LoginOutlook(ctx context.Context, cfg MicrosoftOAuthConfig, out io.Writer, opts ...OutlookLoginOptions) (token *MicrosoftOAuthToken, email string, err error) {
	var opt OutlookLoginOptions
	if len(opts) > 0 {
		opt = opts[0]
	}

	listener, err := listenLocalOutlook()
	if err != nil {
		return nil, "", fmt.Errorf("starting local server: %w", err)
	}
	defer listener.Close()

	addr := listener.Addr().String()
	redirectURI := fmt.Sprintf("http://127.0.0.1:%s%s", auth.PortFromAddr(addr), outlookCallbackPath)

	state, err := auth.RandomState()
	if err != nil {
		return nil, "", fmt.Errorf("generating state: %w", err)
	}
	pkce, err := newPKCEPair()
	if err != nil {
		return nil, "", err
	}

	authorizeURL := buildMicrosoftAuthURL(cfg, redirectURI, state, pkce.challenge)

	resultCh := make(chan outlookCallbackResult, 1)

	returnBlock, closeMS := "", "2000"
	if opt.AppReturn {
		returnBlock = outlookAppReturnBlock
		closeMS = "4500"
	}
	successPage := strings.NewReplacer("<!--RETURN-->", returnBlock, "{{CLOSE_MS}}", closeMS).
		Replace(outlookCallbackSuccessPage)

	mux := http.NewServeMux()
	mux.HandleFunc(outlookCallbackPath, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if errMsg := q.Get("error"); errMsg != "" {
			resultCh <- outlookCallbackResult{err: errMsg}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			// #nosec G705 -- errMsg is html.EscapeString-encoded before
			// interpolation, so this isn't an XSS sink despite the taint
			// analysis (it doesn't track through html.EscapeString).
			fmt.Fprint(w, strings.Replace(outlookCallbackErrorPage, "{{ERROR}}", html.EscapeString(errMsg), 1)) //nolint:gosec
			return
		}
		resultCh <- outlookCallbackResult{
			code:  q.Get("code"),
			state: q.Get("state"),
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, successPage)
	})

	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener) //nolint:errcheck
	defer func() {
		time.Sleep(500 * time.Millisecond)
		server.Close()
	}()

	if opt.SkipBrowserOpen {
		fmt.Fprintf(out, "Authorize URL:\n\n  %s\n\n", authorizeURL)
		fmt.Fprintf(out, "Waiting for authorization callback...\n")
	} else {
		fmt.Fprintf(out, "Opening browser for Outlook authorization...\n")
		fmt.Fprintf(out, "If the browser doesn't open, visit this URL:\n\n  %s\n\n", authorizeURL)
		getOutlookOpenBrowserFunc()(authorizeURL)
	}

	ctx, cancel := context.WithTimeout(ctx, outlookLoginTimeout)
	defer cancel()

	var cb outlookCallbackResult
	select {
	case cb = <-resultCh:
	case <-ctx.Done():
		return nil, "", fmt.Errorf("login timed out after %s", outlookLoginTimeout)
	}

	if cb.err != "" {
		return nil, "", fmt.Errorf("microsoft authorization denied: %s", cb.err)
	}
	if cb.state != state {
		return nil, "", fmt.Errorf("state mismatch: possible CSRF attack")
	}
	if cb.code == "" {
		return nil, "", fmt.Errorf("no authorization code received")
	}

	tok, err := exchangeMicrosoftCode(ctx, cfg, cb.code, redirectURI, pkce.verifier)
	if err != nil {
		return nil, "", fmt.Errorf("exchanging code for token: %w", err)
	}

	if tok.IDToken != "" {
		if resolved, emailErr := idTokenEmail(tok.IDToken); emailErr == nil {
			email = resolved
		}
	}

	return tok, email, nil
}

// listenLocalOutlook tries preferred ports, then falls back to a random port
// — a separate range from Calendar (18501-18510), Jira (18511-18520), and
// Gmail (18521-18530).
func listenLocalOutlook() (net.Listener, error) {
	preferred := []int{18531, 18532, 18533, 18534, 18535, 18536, 18537, 18538, 18539, 18540}
	for _, port := range preferred {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			return ln, nil
		}
	}
	return net.Listen("tcp", "127.0.0.1:0")
}

const outlookCallbackSuccessPage = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Watchtower — Outlook Connected</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#0f0f0f;color:#e5e5e5}
.card{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:16px;padding:48px;max-width:440px;text-align:center}
.logo{width:52px;height:52px;border-radius:13px;background:linear-gradient(135deg,#5b8cff,#3f5be0);color:#fff;font-weight:700;font-size:24px;line-height:52px;margin:0 auto 18px}
h1{font-size:20px;margin-bottom:8px}p{color:#888;font-size:14px}
.btn{display:inline-block;margin-top:22px;padding:13px 32px;background:linear-gradient(135deg,#5b8cff,#3f5be0);color:#fff;text-decoration:none;font-weight:600;font-size:15px;border-radius:10px;box-shadow:0 4px 14px rgba(63,91,224,.35)}
.btn:hover{filter:brightness(1.12)}
.hint{margin-top:12px;color:#666;font-size:12px}</style></head>
<body><div class="card"><div class="logo">W</div><h1>Outlook Connected</h1><p>Outlook has been linked to Watchtower.</p><!--RETURN--></div>
<script>setTimeout(function(){try{window.close()}catch(e){}},{{CLOSE_MS}});</script></body></html>`

// outlookAppReturnBlock is injected into the success page when
// OutlookLoginOptions.AppReturn is set — mirrors gmail's appReturnBlock.
const outlookAppReturnBlock = `<a class="btn" href="watchtower-auth://connected">Open Watchtower</a>
<p class="hint">You can close this tab afterwards.</p>
<script>setTimeout(function(){location.href="watchtower-auth://connected";},3000);</script>`

const outlookCallbackErrorPage = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Watchtower — Error</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#0f0f0f;color:#e5e5e5}
.card{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:16px;padding:48px;max-width:440px;text-align:center}
h1{font-size:20px;margin-bottom:8px}p{color:#888;font-size:14px}</style></head>
<body><div class="card"><h1>Authorization Failed</h1><p>{{ERROR}}</p></div></body></html>`

// RefreshingXOAUTH2Auth authenticates via SASL XOAUTH2, calling RefreshFunc
// on every Authenticate() to obtain a fresh access token. Since Dial calls
// Authenticate once per connection and Syncer.Sync dials once per cycle, a
// long-lived daemon transparently gets a non-expired token every cycle
// without client.go or sync.go needing to know anything about token
// lifetimes or refreshing.
type RefreshingXOAUTH2Auth struct {
	Username    string
	RefreshFunc func(ctx context.Context) (accessToken string, err error)
}

// Authenticate satisfies the Authenticator interface. It has no context
// parameter of its own (mirroring the interface it implements), so
// RefreshFunc runs against context.Background() — the token refresh HTTP call
// is short-lived and doesn't need to inherit Sync's cancellation.
func (a RefreshingXOAUTH2Auth) Authenticate(c *imapclient.Client) error {
	token, err := a.RefreshFunc(context.Background())
	if err != nil {
		return fmt.Errorf("refreshing outlook access token: %w", err)
	}
	return XOAUTH2Auth{Username: a.Username, AccessToken: token}.Authenticate(c)
}
