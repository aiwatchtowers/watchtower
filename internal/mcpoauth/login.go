package mcpoauth

import (
	"context"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"watchtower/internal/auth"
	"watchtower/internal/externalmcp"
)

const (
	callbackPath = "/callback"
	loginTimeout = 5 * time.Minute
)

// OpenBrowser opens the authorization URL; tests swap it to capture the URL
// and drive the callback themselves instead of launching a real browser.
var OpenBrowser = auth.OpenBrowser

// Now is the clock used to stamp OAuthGrant.ExpiresAt; tests swap it.
var Now = time.Now

// LoginConfig describes the MCP server (and optional BYO client credentials)
// a sign-in loop runs against.
type LoginConfig struct {
	ServerURL    string // the MCP server URL (also the RFC 8707 resource)
	ClientID     string // optional: BYO client id when the server has no registration_endpoint
	ClientSecret string // optional: BYO client secret (came in via stdin)
	Scope        string // optional
}

// LoginOptions configures the Login flow's presentation.
type LoginOptions struct {
	SkipBrowserOpen bool // print the URL instead of opening the browser
	AppReturn       bool // success page redirects to watchtower-auth://connected
}

// callbackResult is sent from the HTTP callback handler to the Login goroutine.
type callbackResult struct {
	code  string
	state string
	err   string
}

// Login runs discovery → (registration | BYO client id) → PKCE authorization
// over a 127.0.0.1 HTTP loopback → code exchange, and returns the grant to
// persist. Plain HTTP (not TLS) is used intentionally for the loopback
// redirect URI — the jira.Login precedent.
func Login(ctx context.Context, cfg LoginConfig, out io.Writer, opts LoginOptions) (*externalmcp.OAuthGrant, error) {
	md, err := Discover(ctx, cfg.ServerURL)
	if err != nil {
		return nil, err
	}

	listener, err := listenLocal()
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: starting local server: %w", err)
	}
	defer listener.Close()

	redirectURI := fmt.Sprintf("http://127.0.0.1:%s%s", auth.PortFromAddr(listener.Addr().String()), callbackPath)

	clientID, clientSecret := cfg.ClientID, cfg.ClientSecret
	if clientID == "" {
		if md.RegistrationEndpoint == "" {
			return nil, fmt.Errorf("mcpoauth: server publishes no registration_endpoint; pass --client-id (and --client-secret-stdin if required)")
		}
		clientID, clientSecret, err = Register(ctx, md, redirectURI)
		if err != nil {
			return nil, err
		}
	}

	state, err := auth.RandomState()
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: generating state: %w", err)
	}
	pkce, err := auth.NewPKCEPair()
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: generating PKCE pair: %w", err)
	}

	authorizeURL, err := AuthorizeURL(md, clientID, redirectURI, state, pkce, cfg.Scope, cfg.ServerURL)
	if err != nil {
		return nil, err
	}

	resultCh := make(chan callbackResult, 1)

	// With app-return the success page sits briefly (so the confirmation is
	// readable and the redirect doesn't race page load), then navigates to the
	// app scheme; without it the tab just self-closes (the jira.Login precedent).
	returnBlock, closeMS := "", "2000"
	if opts.AppReturn {
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
		resultCh <- callbackResult{code: q.Get("code"), state: q.Get("state")}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, successPage)
	})

	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener) //nolint:errcheck
	defer func() {
		// Grace period to let the browser receive the HTML response before closing.
		time.Sleep(500 * time.Millisecond)
		server.Close()
	}()

	fmt.Fprintf(out, "Open this URL to sign in:\n%s\n", authorizeURL)
	if !opts.SkipBrowserOpen {
		OpenBrowser(authorizeURL)
	}

	ctx, cancel := context.WithTimeout(ctx, loginTimeout)
	defer cancel()

	var cb callbackResult
	select {
	case cb = <-resultCh:
	case <-ctx.Done():
		return nil, fmt.Errorf("mcpoauth: login timed out or was cancelled: %w", ctx.Err())
	}

	if cb.err != "" {
		return nil, fmt.Errorf("mcpoauth: authorization denied: %s", cb.err)
	}
	if cb.state != state {
		return nil, fmt.Errorf("mcpoauth: state mismatch: possible CSRF attack")
	}
	if cb.code == "" {
		return nil, fmt.Errorf("mcpoauth: no authorization code received")
	}

	tok, err := ExchangeCode(ctx, md, clientID, clientSecret, cb.code, redirectURI, pkce.Verifier, cfg.ServerURL)
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: exchanging code for token: %w", err)
	}

	grant := &externalmcp.OAuthGrant{
		AccessToken:        tok.AccessToken,
		RefreshToken:       tok.RefreshToken,
		TokenEndpoint:      md.TokenEndpoint,
		ClientID:           clientID,
		ClientSecret:       clientSecret,
		Scope:              tok.Scope,
		Resource:           cfg.ServerURL,
		RevocationEndpoint: md.RevocationEndpoint,
	}
	if tok.ExpiresIn > 0 {
		grant.ExpiresAt = Now().Add(time.Duration(tok.ExpiresIn) * time.Second)
	}
	return grant, nil
}

// listenLocal tries preferred ports (18531-18540), then falls back to a
// random port — its own range, distinct from calendar/jira/gmail's.
func listenLocal() (net.Listener, error) {
	for port := 18531; port <= 18540; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			return ln, nil
		}
	}
	return net.Listen("tcp", "127.0.0.1:0")
}
