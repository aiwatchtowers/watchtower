// Package linear implements the Linear connector: OAuth (PKCE over a loopback
// redirect, rotating refresh, revoke) and the per-account token store.
package linear

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"watchtower/internal/auth"
	"watchtower/internal/oauthpage"
)

// DefaultLinearClientID is injected at build time:
// -ldflags "-X watchtower/internal/linear.DefaultLinearClientID=...".
var DefaultLinearClientID string

var (
	authorizeEndpoint = "https://linear.app/oauth/authorize"
	tokenEndpoint     = "https://api.linear.app/oauth/token"
	revokeEndpoint    = "https://api.linear.app/oauth/revoke"
)

// Scopes is the scope set requested at login.
const Scopes = "read,write,issues:create,comments:create"

const (
	callbackPath = "/callback"
	loginTimeout = 5 * time.Minute
)

// tokenHTTPClient serves the token and revoke endpoints. Its timeout is
// load-bearing: a refresh runs under Client.mu and the cross-process token
// lock, so a stalled endpoint must not hold them (and the sync phase) forever.
var tokenHTTPClient = &http.Client{Timeout: 30 * time.Second}

// ErrAuthRevoked means the refresh token was rejected (invalid_grant): the
// owner must sign in again.
var ErrAuthRevoked = errors.New("linear auth revoked")

// OAuthConfig holds the public OAuth app credentials (PKCE, no client secret).
type OAuthConfig struct{ ClientID string }

// LoginOptions configures the Login flow behaviour.
type LoginOptions struct {
	SkipBrowserOpen bool
	// AppReturn adds the "Back to Watchtower" link to the callback page.
	AppReturn bool
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

func authorizeURL(cfg OAuthConfig, redirectURI, state, challenge string) string {
	q := url.Values{
		"client_id":             {cfg.ClientID},
		"redirect_uri":          {redirectURI},
		"response_type":         {"code"},
		"scope":                 {Scopes},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"actor":                 {"user"},
		"prompt":                {"consent"},
	}
	return authorizeEndpoint + "?" + q.Encode()
}

// redirectPorts must each be registered as http://localhost:<port>/callback on
// the Linear OAuth app: Linear matches redirect URIs exactly, so there is no
// random-port fallback (unlike jira.listenLocal).
var redirectPorts = []int{18531, 18532, 18533, 18534, 18535}

func listenLocal() (net.Listener, error) {
	for _, p := range redirectPorts {
		if ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p)); err == nil {
			return ln, nil
		}
	}
	return nil, fmt.Errorf("ports %d-%d are busy; close the program holding them and retry",
		redirectPorts[0], redirectPorts[len(redirectPorts)-1])
}

// Login performs the Linear OAuth2 authorization-code flow with PKCE via a
// local HTTP callback server. Plain HTTP is intentional for loopback redirects.
func Login(ctx context.Context, cfg OAuthConfig, out io.Writer, opt LoginOptions) (*Token, error) {
	listener, err := listenLocal()
	if err != nil {
		return nil, fmt.Errorf("starting local server: %w", err)
	}
	defer listener.Close()

	redirectURI := fmt.Sprintf("http://localhost:%s%s", auth.PortFromAddr(listener.Addr().String()), callbackPath)

	state, err := auth.RandomState()
	if err != nil {
		return nil, fmt.Errorf("generating state: %w", err)
	}
	pkce, err := auth.NewPKCEPair()
	if err != nil {
		return nil, err
	}
	authURL := authorizeURL(cfg, redirectURI, state, pkce.Challenge)

	successPage := oauthpage.Success("Linear", opt.AppReturn)
	errorPage := func(reason string) string { return oauthpage.Error(reason, opt.AppReturn) }

	mux := http.NewServeMux()
	callback, resultCh := auth.NewCallbackHandler(state, successPage, errorPage)
	mux.HandleFunc(callbackPath, callback)

	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener)
	defer func() {
		time.Sleep(500 * time.Millisecond)
		server.Close()
	}()

	if opt.SkipBrowserOpen {
		fmt.Fprintf(out, "Authorize URL:\n\n  %s\n\n", authURL)
		fmt.Fprintf(out, "Waiting for authorization callback...\n")
	} else {
		fmt.Fprintf(out, "Opening browser for Linear authorization...\n")
		fmt.Fprintf(out, "If the browser doesn't open, visit this URL:\n\n  %s\n\n", authURL)
		getOpenBrowserFunc()(authURL)
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
		return nil, fmt.Errorf("linear authorization denied: %s", cb.Err)
	}
	if cb.Code == "" {
		return nil, fmt.Errorf("no authorization code received")
	}

	token, err := exchangeCode(ctx, cfg, cb.Code, pkce.Verifier, redirectURI, tokenEndpoint)
	if err != nil {
		return nil, fmt.Errorf("exchanging code for token: %w", err)
	}
	return token, nil
}

func postToken(ctx context.Context, endpoint string, form url.Values) (*Token, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := tokenHTTPClient.Do(req) // endpoint is a package var, overridden only by tests
	if err != nil {
		return nil, fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		if form.Get("grant_type") == "refresh_token" && strings.Contains(string(body), "invalid_grant") {
			return nil, fmt.Errorf("%w: %s", ErrAuthRevoked, strings.TrimSpace(string(body)))
		}
		return nil, fmt.Errorf("token endpoint returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var t Token
	if err := json.Unmarshal(body, &t); err != nil {
		return nil, fmt.Errorf("parsing token: %w", err)
	}
	if t.ExpiresIn > 0 {
		t.Expiry = time.Now().Add(time.Duration(t.ExpiresIn) * time.Second).UTC().Format(time.RFC3339)
	}
	return &t, nil
}

func exchangeCode(ctx context.Context, cfg OAuthConfig, code, verifier, redirectURI, endpoint string) (*Token, error) {
	return postToken(ctx, endpoint, url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirectURI},
		"client_id": {cfg.ClientID}, "code_verifier": {verifier},
	})
}

func refreshToken(ctx context.Context, cfg OAuthConfig, refresh, endpoint string) (*Token, error) {
	t, err := postToken(ctx, endpoint, url.Values{
		"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {cfg.ClientID},
	})
	if err != nil {
		return nil, err
	}
	if t.RefreshToken == "" { // Linear rotates, but never lose the old one if a response omits it
		t.RefreshToken = refresh
	}
	return t, nil
}

// Revoke revokes an access token. 200 and 400 (already revoked) are success.
func Revoke(ctx context.Context, accessToken string) error {
	form := url.Values{"token": {accessToken}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, revokeEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := tokenHTTPClient.Do(req) // endpoint is a package var, overridden only by tests
	if err != nil {
		return fmt.Errorf("revoke request: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusBadRequest {
		return nil
	}
	return fmt.Errorf("revoke endpoint returned %d", resp.StatusCode)
}
