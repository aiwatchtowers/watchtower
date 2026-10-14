// Package auth provides OAuth and authentication handling for Slack integration.
package auth

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"watchtower/internal/oauthpage"

	"github.com/slack-go/slack"
)

// defaultRedirectPort is the fixed port used for the in-app OAuth redirect URI.
// The desktop app intercepts this redirect in WKWebView before it loads,
// so no server needs to be running.
const defaultRedirectPort = 18491

const (
	slackAuthorizeURL = "https://slack.com/oauth/v2/authorize"
	callbackPath      = "/callback"
	loginTimeout      = 5 * time.Minute
)

// DefaultClientID and DefaultClientSecret are the Slack app credentials
// for the Watchtower CLI. They are injected at build time via -ldflags:
//
//	-X watchtower/internal/auth.DefaultClientID=...
//	-X watchtower/internal/auth.DefaultClientSecret=...
//
// Override at runtime with WATCHTOWER_OAUTH_CLIENT_ID / WATCHTOWER_OAUTH_CLIENT_SECRET.
var (
	DefaultClientID     string
	DefaultClientSecret string
)

// UserScopes are the Slack user token scopes required by Watchtower.
var UserScopes = []string{
	"channels:history", "channels:read", "channels:write",
	"groups:history", "groups:read", "groups:write",
	"im:history", "im:read", "im:write",
	"mpim:history", "mpim:read", "mpim:write",
	"search:read",
	"users:read", "users:read.email",
	"files:read", "reactions:read", "team:read",
	// Sending from the assistant (send_slack_message, behind the owner's
	// Approve). Accounts connected before it was asked for re-consent.
	"chat:write",
}

// exchangeToken is the function used to exchange an OAuth code for a token.
// Tests replace this to avoid hitting the real Slack API.
var exchangeToken = func(ctx context.Context, clientID, clientSecret, code, redirectURI string) (*slack.OAuthV2Response, error) {
	return slack.GetOAuthV2ResponseContext(ctx, http.DefaultClient, clientID, clientSecret, code, redirectURI)
}

// openBrowserFunc can be replaced in tests to avoid opening a real browser.
var (
	openBrowserMu   sync.Mutex
	openBrowserFunc = OpenBrowser
)

func getOpenBrowserFunc() func(string) {
	openBrowserMu.Lock()
	defer openBrowserMu.Unlock()
	return openBrowserFunc
}

func setOpenBrowserFunc(f func(string)) {
	openBrowserMu.Lock()
	defer openBrowserMu.Unlock()
	openBrowserFunc = f
}

// OAuthConfig holds the Slack app credentials for the OAuth flow.
type OAuthConfig struct {
	ClientID     string
	ClientSecret string
}

// OAuthResult holds the result of a successful OAuth login.
type OAuthResult struct {
	AccessToken string
	TeamID      string
	TeamName    string
	UserID      string
	ExpiresIn   int
	// Scope is the comma-separated user scopes Slack actually granted.
	Scope string
}

// PrepareResult holds the data needed by the desktop app to start the OAuth flow.
type PrepareResult struct {
	AuthorizeURL string `json:"authorize_url"`
	RedirectURI  string `json:"redirect_uri"`
	State        string `json:"state"`
}

// Prepare generates an OAuth authorization URL for the desktop app.
// If customRedirectURI is non-empty it is used instead of the default localhost HTTPS redirect.
// The desktop app uses a custom scheme (e.g. watchtower-auth://callback) so that
// ASWebAuthenticationSession can intercept the redirect automatically.
func Prepare(cfg OAuthConfig, customRedirectURI string) (*PrepareResult, error) {
	state, err := RandomState()
	if err != nil {
		return nil, fmt.Errorf("generating state: %w", err)
	}

	redirectURI := customRedirectURI
	if redirectURI == "" {
		redirectURI = fmt.Sprintf("https://127.0.0.1:%d%s", defaultRedirectPort, callbackPath)
	}

	params := url.Values{
		"client_id":    {cfg.ClientID},
		"user_scope":   {strings.Join(UserScopes, ",")},
		"redirect_uri": {redirectURI},
		"state":        {state},
	}
	authorizeURL := slackAuthorizeURL + "?" + params.Encode()

	return &PrepareResult{
		AuthorizeURL: authorizeURL,
		RedirectURI:  redirectURI,
		State:        state,
	}, nil
}

// Complete exchanges an OAuth authorization code for a user token.
// Used by the desktop app after intercepting the redirect callback.
func Complete(ctx context.Context, cfg OAuthConfig, code, redirectURI string) (*OAuthResult, error) {
	if code == "" {
		return nil, fmt.Errorf("no authorization code provided")
	}

	resp, err := exchangeToken(ctx, cfg.ClientID, cfg.ClientSecret, code, redirectURI)
	if err != nil {
		return nil, fmt.Errorf("exchanging code for token: %w", err)
	}

	result := &OAuthResult{
		AccessToken: resp.AuthedUser.AccessToken,
		TeamID:      resp.Team.ID,
		TeamName:    resp.Team.Name,
		UserID:      resp.AuthedUser.ID,
		ExpiresIn:   resp.AuthedUser.ExpiresIn,
		Scope:       resp.AuthedUser.Scope,
	}

	if result.AccessToken == "" {
		return nil, fmt.Errorf("no user access token in response (did you configure user_scope in your Slack app?)")
	}

	return result, nil
}

// callbackResult is sent from the HTTP callback handler to the Login goroutine.
type callbackResult struct {
	code  string
	state string
	err   string
}

// LoginOptions configures the Login flow behaviour.
type LoginOptions struct {
	// SkipBrowserOpen disables automatic browser launch; the authorize URL is still printed.
	SkipBrowserOpen bool
	// AppReturn adds the "Back to Watchtower" link to the callback page
	// (oauthpage); the CLI command brings the app back itself
	// (oauthpage.ReturnAfterLogin). Off for plain CLI logins.
	AppReturn bool
}

// Login performs the Slack OAuth V2 flow:
// - Starts a temporary HTTPS server on localhost (self-signed cert)
// - Opens the Slack authorize URL in the user's browser
// - Waits for the callback with an authorization code
// - Exchanges the code for a user token
func Login(ctx context.Context, cfg OAuthConfig, out io.Writer, opts ...LoginOptions) (*OAuthResult, error) {
	var opt LoginOptions
	if len(opts) > 0 {
		opt = opts[0]
	}
	// Use persistent TLS cert (generated once, can be trusted via `auth trust-cert`)
	tlsCert, err := EnsureCert()
	if err != nil {
		return nil, fmt.Errorf("loading TLS certificate: %w", err)
	}

	// Find an available port
	listener, err := ListenLocalTLS(tlsCert)
	if err != nil {
		return nil, fmt.Errorf("starting local server: %w", err)
	}
	defer listener.Close()

	// Extract port from the underlying TCP listener address
	addr := listener.Addr().String()
	redirectURI := fmt.Sprintf("https://127.0.0.1:%s%s", PortFromAddr(addr), callbackPath)

	// Generate random state
	state, err := RandomState()
	if err != nil {
		return nil, fmt.Errorf("generating state: %w", err)
	}

	// Build authorize URL with user_scope (not scope) for user tokens
	params := url.Values{
		"client_id":    {cfg.ClientID},
		"user_scope":   {strings.Join(UserScopes, ",")},
		"redirect_uri": {redirectURI},
		"state":        {state},
	}
	authorizeURL := slackAuthorizeURL + "?" + params.Encode()

	resultCh := make(chan callbackResult, 1)

	successPage := oauthpage.Success("Slack", opt.AppReturn)

	mux := http.NewServeMux()
	mux.HandleFunc(callbackPath, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if errMsg := q.Get("error"); errMsg != "" {
			resultCh <- callbackResult{err: errMsg}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, oauthpage.Error(errMsg, opt.AppReturn)) //nolint:gosec // G705: oauthpage.Error renders the reason through html/template
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
	go server.Serve(listener)
	defer func() {
		// Grace period to let the browser receive the HTML response before closing.
		time.Sleep(500 * time.Millisecond)
		server.Close()
	}()

	// Print URL and optionally open browser
	if opt.SkipBrowserOpen {
		fmt.Fprintf(out, "Authorize URL:\n\n  %s\n\n", authorizeURL)
		fmt.Fprintf(out, "Waiting for authorization callback...\n")
	} else {
		fmt.Fprintf(out, "Opening browser for Slack authorization...\n")
		fmt.Fprintf(out, "If the browser doesn't open, visit this URL:\n\n  %s\n\n", authorizeURL)
		getOpenBrowserFunc()(authorizeURL)
	}

	// Wait for callback or timeout
	ctx, cancel := context.WithTimeout(ctx, loginTimeout)
	defer cancel()

	var cb callbackResult
	select {
	case cb = <-resultCh:
	case <-ctx.Done():
		return nil, fmt.Errorf("%w after %s", oauthpage.ErrLoginTimedOut, loginTimeout)
	}

	if cb.err != "" {
		return nil, fmt.Errorf("slack authorization denied: %s", cb.err)
	}

	if cb.state != state {
		return nil, fmt.Errorf("state mismatch: possible CSRF attack")
	}

	if cb.code == "" {
		return nil, fmt.Errorf("no authorization code received")
	}

	// Exchange code for token
	resp, err := exchangeToken(ctx, cfg.ClientID, cfg.ClientSecret, cb.code, redirectURI)
	if err != nil {
		return nil, fmt.Errorf("exchanging code for token: %w", err)
	}

	result := &OAuthResult{
		AccessToken: resp.AuthedUser.AccessToken,
		TeamID:      resp.Team.ID,
		TeamName:    resp.Team.Name,
		UserID:      resp.AuthedUser.ID,
		ExpiresIn:   resp.AuthedUser.ExpiresIn,
		Scope:       resp.AuthedUser.Scope,
	}

	if result.AccessToken == "" {
		return nil, fmt.Errorf("no user access token in response (did you configure user_scope in your Slack app?)")
	}

	return result, nil
}

// generateSelfSignedCert creates a short-lived self-signed TLS certificate for 127.0.0.1.
func generateSelfSignedCert() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}

	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "Watchtower OAuth Callback"},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(10 * time.Minute),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1)},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}

	return tls.Certificate{
		Certificate: [][]byte{certDER},
		PrivateKey:  key,
	}, nil
}

// ListenLocalTLS tries preferred ports with TLS, then falls back to a random port.
func ListenLocalTLS(cert tls.Certificate) (net.Listener, error) {
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	preferred := []int{18491, 18492, 18493, 18494, 18495, 18496, 18497, 18498, 18499, 18500}
	for _, port := range preferred {
		ln, err := tls.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port), tlsConfig)
		if err == nil {
			return ln, nil
		}
	}
	return tls.Listen("tcp", "127.0.0.1:0", tlsConfig)
}

// PortFromAddr extracts the port from a "host:port" address string.
func PortFromAddr(addr string) string {
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return port
}

// RandomState generates a cryptographically random hex string.
func RandomState() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// OpenBrowser opens a URL in the user's default browser.
func OpenBrowser(rawURL string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		// Plain `open` (no -n): -n launched a NEW INSTANCE of the browser per
		// call — repeated logins piled up browser instances/windows.
		cmd = exec.Command("open", rawURL)
	case "linux":
		cmd = exec.Command("xdg-open", rawURL)
	default:
		return
	}
	if err := cmd.Start(); err == nil {
		go cmd.Wait() // reap child process to avoid zombie
	}
}
