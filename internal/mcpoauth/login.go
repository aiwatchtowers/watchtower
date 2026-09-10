package mcpoauth

import (
	"context"
	"crypto/subtle"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
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

// loginResult is what the /callback handler hands back to Login: either the
// finished grant (state validated, code exchanged) or the error that should
// be returned to the caller — the handler decides which page the browser
// sees based on the very same outcome, so the two can never disagree.
type loginResult struct {
	grant *externalmcp.OAuthGrant
	err   error
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

	// loginCtx bounds the whole wait for the callback (including the code
	// exchange the handler performs once it arrives) — derived once, up
	// front, so the handler closure below and the final select share it.
	loginCtx, cancel := context.WithTimeout(ctx, loginTimeout)
	defer cancel()

	resultCh := make(chan loginResult, 1)
	var delivered atomic.Bool

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
		// Only the first request to reach the callback delivers a result —
		// a retry, a stray local probe, or a second race for the port gets a
		// bare status with no page and never touches resultCh again.
		if !delivered.CompareAndSwap(false, true) {
			w.WriteHeader(http.StatusGone)
			return
		}

		// deliver is non-blocking by construction (delivered's CAS guarantees
		// at most one send), but select+default keeps that true even if that
		// invariant is ever weakened.
		deliver := func(res loginResult, page string) {
			select {
			case resultCh <- res:
			default:
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, page)
		}
		fail := func(userMsg, errText string) {
			page := strings.Replace(callbackErrorPage, "{{ERROR}}", html.EscapeString(userMsg), 1)
			deliver(loginResult{err: fmt.Errorf("mcpoauth: %s", errText)}, page)
		}

		q := r.URL.Query()
		if errMsg := q.Get("error"); errMsg != "" {
			fail(errMsg, fmt.Sprintf("authorization denied: %s", errMsg))
			return
		}
		if got := q.Get("state"); subtle.ConstantTimeCompare([]byte(got), []byte(state)) != 1 {
			fail("state mismatch: possible CSRF attack", "state mismatch: possible CSRF attack")
			return
		}
		code := q.Get("code")
		if code == "" {
			fail("no authorization code received", "no authorization code received")
			return
		}

		tok, err := ExchangeCode(loginCtx, md, clientID, clientSecret, code, redirectURI, pkce.Verifier, cfg.ServerURL)
		if err != nil {
			fail(err.Error(), fmt.Sprintf("exchanging code for token: %s", err))
			return
		}

		grant := buildGrant(tok, md, clientID, clientSecret, cfg.ServerURL)
		deliver(loginResult{grant: grant}, successPage)
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

	select {
	case res := <-resultCh:
		return res.grant, res.err
	case <-loginCtx.Done():
		return nil, fmt.Errorf("mcpoauth: login timed out or was cancelled: %w", loginCtx.Err())
	}
}

// buildGrant assembles the OAuthGrant to persist from the token endpoint's
// response, the resolved client identity, and the discovered metadata. A
// zero or absent ExpiresIn leaves ExpiresAt zero (OAuthGrant.Expiring
// treats a zero ExpiresAt as never expiring) rather than stamping a bogus
// "expires now".
func buildGrant(tok *Token, md *Metadata, clientID, clientSecret, resource string) *externalmcp.OAuthGrant {
	grant := &externalmcp.OAuthGrant{
		AccessToken:        tok.AccessToken,
		RefreshToken:       tok.RefreshToken,
		TokenEndpoint:      md.TokenEndpoint,
		ClientID:           clientID,
		ClientSecret:       clientSecret,
		Scope:              tok.Scope,
		Resource:           resource,
		RevocationEndpoint: md.RevocationEndpoint,
	}
	if tok.ExpiresIn > 0 {
		grant.ExpiresAt = Now().Add(time.Duration(tok.ExpiresIn) * time.Second)
	}
	return grant
}

// listenLocal tries preferred ports (18541-18550), then falls back to a
// random port. Each loopback OAuth flow in the codebase owns a disjoint
// range: Slack 18491-500, Calendar 18501-510, Jira 18511-520, Gmail
// 18521-530, Outlook/IMAP 18531-540 — this one is 18541-18550.
func listenLocal() (net.Listener, error) {
	for port := 18541; port <= 18550; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			return ln, nil
		}
	}
	return net.Listen("tcp", "127.0.0.1:0")
}
