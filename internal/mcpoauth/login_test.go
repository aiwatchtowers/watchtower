package mcpoauth

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// syncBuffer is a mutex-guarded io.Writer, used where a goroutine writes
// (Login's progress output) while the test goroutine concurrently reads —
// the internal/gmail/auth_test.go syncBuffer precedent.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
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

// captureAuthorizeURL swaps OpenBrowser so it hands the authorize URL to
// the test on a channel instead of launching a real browser — the test's
// main goroutine then drives the loopback callback itself, synchronously,
// once it has the URL (and whatever it needs out of its query: state,
// redirect_uri, code_challenge).
func captureAuthorizeURL(t *testing.T) <-chan string {
	t.Helper()
	old := OpenBrowser
	t.Cleanup(func() { OpenBrowser = old })
	ch := make(chan string, 1)
	OpenBrowser = func(rawURL string) { ch <- rawURL }
	return ch
}

// hitCallback GETs redirectURI with params merged into its query — the
// browser's side of following an authorization server's redirect — and
// returns the loopback server's raw response.
func hitCallback(t *testing.T, redirectURI string, params map[string]string) (status int, body string) {
	t.Helper()
	u, err := url.Parse(redirectURI)
	if err != nil {
		t.Fatalf("parsing redirect_uri %q: %v", redirectURI, err)
	}
	q := u.Query()
	for k, v := range params {
		q.Set(k, v)
	}
	u.RawQuery = q.Encode()

	resp, err := http.Get(u.String()) //nolint:gosec,noctx
	if err != nil {
		t.Fatalf("GET %s: %v", u, err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("reading callback response body: %v", err)
	}
	return resp.StatusCode, string(b)
}

// waitForSubstring polls buf until it contains substr or the deadline
// passes, failing the test on timeout — avoids a blind sleep racing
// Login's goroutine.
func waitForSubstring(t *testing.T, buf *syncBuffer, substr string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if strings.Contains(buf.String(), substr) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %q in output; got %q", substr, buf.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// startLogin runs Login in a background goroutine and returns a channel
// delivering its (grant, err) result, so the test's main goroutine is free
// to capture the authorize URL and drive the callback synchronously.
func startLogin(cfg LoginConfig, out io.Writer, opts LoginOptions) <-chan loginResult {
	ch := make(chan loginResult, 1)
	go func() {
		grant, err := Login(context.Background(), cfg, out, opts)
		ch <- loginResult{grant: grant, err: err}
	}()
	return ch
}

func TestLogin_HappyPath(t *testing.T) {
	as := newFakeAS(t)

	oldNow := Now
	fixedNow := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	Now = func() time.Time { return fixedNow }
	t.Cleanup(func() { Now = oldNow })

	urlCh := captureAuthorizeURL(t)
	var out bytes.Buffer
	resultCh := startLogin(LoginConfig{ServerURL: as.server.URL}, &out, LoginOptions{})

	authorizeURL := <-urlCh
	u, err := url.Parse(authorizeURL)
	if err != nil {
		t.Fatalf("parsing authorize URL: %v", err)
	}
	q := u.Query()

	if q.Get("code_challenge_method") != "S256" {
		t.Errorf("code_challenge_method = %q, want S256", q.Get("code_challenge_method"))
	}
	if q.Get("resource") != as.server.URL {
		t.Errorf("resource = %q, want %q", q.Get("resource"), as.server.URL)
	}
	// Pin the PKCE binding: fakeAS now actually enforces that the
	// code_verifier ExchangeCode sends hashes to THIS challenge — mutating
	// the verifier Login uses must fail this test.
	as.SetCodeChallenge(q.Get("code_challenge"))

	redirectURI := q.Get("redirect_uri")
	ru, err := url.Parse(redirectURI)
	if err != nil {
		t.Fatalf("parsing redirect_uri: %v", err)
	}
	if ru.Hostname() != "127.0.0.1" {
		t.Errorf("redirect_uri host = %q, want 127.0.0.1 (loopback binding pinned)", ru.Hostname())
	}
	if ru.Path != "/callback" {
		t.Errorf("redirect_uri path = %q, want /callback", ru.Path)
	}

	status, body := hitCallback(t, redirectURI, map[string]string{"code": as.AuthCode, "state": q.Get("state")})
	if status != http.StatusOK {
		t.Errorf("callback status = %d, want 200", status)
	}
	if !strings.Contains(body, "Connected") {
		t.Errorf("callback body = %q, want the success page", body)
	}

	res := <-resultCh
	if res.err != nil {
		t.Fatalf("Login: %v", res.err)
	}
	grant := res.grant

	if grant.AccessToken != as.AccessToken {
		t.Errorf("AccessToken = %q, want %q", grant.AccessToken, as.AccessToken)
	}
	if grant.RefreshToken != as.RefreshToken {
		t.Errorf("RefreshToken = %q, want %q", grant.RefreshToken, as.RefreshToken)
	}
	wantExpiry := fixedNow.Add(3600 * time.Second)
	if !grant.ExpiresAt.Equal(wantExpiry) {
		t.Errorf("ExpiresAt = %v, want %v", grant.ExpiresAt, wantExpiry)
	}
	if grant.ClientID != as.ClientID {
		t.Errorf("ClientID = %q, want %q (issued by registration)", grant.ClientID, as.ClientID)
	}
	if grant.TokenEndpoint != as.server.URL+"/token" {
		t.Errorf("TokenEndpoint = %q, want %q", grant.TokenEndpoint, as.server.URL+"/token")
	}
	if grant.RevocationEndpoint != as.server.URL+"/revoke" {
		t.Errorf("RevocationEndpoint = %q, want %q", grant.RevocationEndpoint, as.server.URL+"/revoke")
	}
	if grant.Resource != as.server.URL {
		t.Errorf("Resource = %q, want %q", grant.Resource, as.server.URL)
	}
	if len(as.RegisterRequests) != 1 {
		t.Errorf("RegisterRequests = %d, want 1 (DCR should run with no BYO client id)", len(as.RegisterRequests))
	}
	if !strings.Contains(out.String(), "Open this URL to sign in") {
		t.Errorf("out = %q, want it to contain the authorize URL prompt", out.String())
	}
}

func TestLogin_StateMismatchRejected(t *testing.T) {
	as := newFakeAS(t)

	urlCh := captureAuthorizeURL(t)
	resultCh := startLogin(LoginConfig{ServerURL: as.server.URL}, &syncBuffer{}, LoginOptions{})

	authorizeURL := <-urlCh
	u, err := url.Parse(authorizeURL)
	if err != nil {
		t.Fatalf("parsing authorize URL: %v", err)
	}
	redirectURI := u.Query().Get("redirect_uri")

	status, body := hitCallback(t, redirectURI, map[string]string{"code": as.AuthCode, "state": "wrong-state"})
	if status != http.StatusOK {
		t.Errorf("callback status = %d, want 200 (the error page still renders normally)", status)
	}
	if !strings.Contains(body, "Authorization Failed") {
		t.Errorf("callback body = %q, want the error page for a state mismatch", body)
	}
	if strings.Contains(body, "This connection has been signed in") {
		t.Errorf("callback body = %q, want NOT the success page on a state mismatch", body)
	}

	res := <-resultCh
	if res.err == nil {
		t.Fatal("Login: want error for a state mismatch, got nil")
	}
	if !strings.Contains(res.err.Error(), "state mismatch") {
		t.Errorf("Login: err = %v, want it to mention state mismatch", res.err)
	}
}

func TestLogin_ErrorQueryParamServesErrorPage(t *testing.T) {
	as := newFakeAS(t)

	urlCh := captureAuthorizeURL(t)
	resultCh := startLogin(LoginConfig{ServerURL: as.server.URL}, &syncBuffer{}, LoginOptions{})

	authorizeURL := <-urlCh
	u, err := url.Parse(authorizeURL)
	if err != nil {
		t.Fatalf("parsing authorize URL: %v", err)
	}
	redirectURI := u.Query().Get("redirect_uri")

	status, body := hitCallback(t, redirectURI, map[string]string{"error": "access_denied"})
	if status != http.StatusOK {
		t.Errorf("callback status = %d, want 200", status)
	}
	if !strings.Contains(body, "Authorization Failed") {
		t.Errorf("callback body = %q, want the error page", body)
	}
	if !strings.Contains(body, "access_denied") {
		t.Errorf("callback body = %q, want it to include the provider's error", body)
	}

	res := <-resultCh
	if res.err == nil {
		t.Fatal("Login: want error when the provider reports error=, got nil")
	}
	if !strings.Contains(res.err.Error(), "authorization denied") {
		t.Errorf("Login: err = %v, want it to mention authorization denied", res.err)
	}
}

func TestLogin_ExchangeFailureServesErrorPage(t *testing.T) {
	as := newFakeAS(t)

	urlCh := captureAuthorizeURL(t)
	resultCh := startLogin(LoginConfig{ServerURL: as.server.URL}, &syncBuffer{}, LoginOptions{})

	authorizeURL := <-urlCh
	u, err := url.Parse(authorizeURL)
	if err != nil {
		t.Fatalf("parsing authorize URL: %v", err)
	}
	q := u.Query()
	redirectURI := q.Get("redirect_uri")

	// A code the fake authorization server never issued: /token rejects it
	// with invalid_grant, so ExchangeCode fails inside the handler itself.
	status, body := hitCallback(t, redirectURI, map[string]string{"code": "not-the-real-code", "state": q.Get("state")})
	if status != http.StatusOK {
		t.Errorf("callback status = %d, want 200", status)
	}
	if !strings.Contains(body, "Authorization Failed") {
		t.Errorf("callback body = %q, want the error page when the code exchange fails", body)
	}
	if strings.Contains(body, "This connection has been signed in") {
		t.Errorf("callback body = %q, want NOT the success page when the code exchange fails", body)
	}

	res := <-resultCh
	if res.err == nil {
		t.Fatal("Login: want error when the code exchange fails, got nil")
	}
	if !strings.Contains(res.err.Error(), "exchanging code for token") {
		t.Errorf("Login: err = %v, want it to mention the exchange failure", res.err)
	}
}

func TestLogin_BYOClientIDSkipsRegistration(t *testing.T) {
	as := newFakeAS(t)

	urlCh := captureAuthorizeURL(t)
	resultCh := startLogin(LoginConfig{ServerURL: as.server.URL, ClientID: "byo-client-id"}, &syncBuffer{}, LoginOptions{})

	authorizeURL := <-urlCh
	u, err := url.Parse(authorizeURL)
	if err != nil {
		t.Fatalf("parsing authorize URL: %v", err)
	}
	q := u.Query()
	as.SetCodeChallenge(q.Get("code_challenge"))

	status, _ := hitCallback(t, q.Get("redirect_uri"), map[string]string{"code": as.AuthCode, "state": q.Get("state")})
	if status != http.StatusOK {
		t.Errorf("callback status = %d, want 200", status)
	}

	res := <-resultCh
	if res.err != nil {
		t.Fatalf("Login: %v", res.err)
	}
	if res.grant.ClientID != "byo-client-id" {
		t.Errorf("ClientID = %q, want %q", res.grant.ClientID, "byo-client-id")
	}
	if len(as.RegisterRequests) != 0 {
		t.Errorf("RegisterRequests = %d, want 0 when a BYO client id is passed", len(as.RegisterRequests))
	}
}

func TestLogin_AppReturn_SuccessPageRedirects(t *testing.T) {
	as := newFakeAS(t)

	urlCh := captureAuthorizeURL(t)
	resultCh := startLogin(LoginConfig{ServerURL: as.server.URL}, &syncBuffer{}, LoginOptions{AppReturn: true})

	authorizeURL := <-urlCh
	u, err := url.Parse(authorizeURL)
	if err != nil {
		t.Fatalf("parsing authorize URL: %v", err)
	}
	q := u.Query()
	as.SetCodeChallenge(q.Get("code_challenge"))

	status, body := hitCallback(t, q.Get("redirect_uri"), map[string]string{"code": as.AuthCode, "state": q.Get("state")})
	if status != http.StatusOK {
		t.Errorf("callback status = %d, want 200", status)
	}
	if !strings.Contains(body, "watchtower-auth://connected") {
		t.Errorf("callback body = %q, want the app-return redirect", body)
	}
	if !strings.Contains(body, "4500") {
		t.Errorf("callback body = %q, want the app-return close delay (4500ms)", body)
	}

	res := <-resultCh
	if res.err != nil {
		t.Fatalf("Login: %v", res.err)
	}
}

func TestLogin_SecondCallbackHitIgnored(t *testing.T) {
	as := newFakeAS(t)

	urlCh := captureAuthorizeURL(t)
	resultCh := startLogin(LoginConfig{ServerURL: as.server.URL}, &syncBuffer{}, LoginOptions{})

	authorizeURL := <-urlCh
	u, err := url.Parse(authorizeURL)
	if err != nil {
		t.Fatalf("parsing authorize URL: %v", err)
	}
	q := u.Query()
	as.SetCodeChallenge(q.Get("code_challenge"))
	redirectURI := q.Get("redirect_uri")
	params := map[string]string{"code": as.AuthCode, "state": q.Get("state")}

	status1, body1 := hitCallback(t, redirectURI, params)
	if status1 != http.StatusOK {
		t.Fatalf("first callback status = %d, want 200", status1)
	}
	if !strings.Contains(body1, "Connected") {
		t.Fatalf("first callback body = %q, want the success page", body1)
	}

	// A second hit on the same callback (retry, stray local probe), fired
	// right after the first while the loopback server is still up — Login
	// itself won't return (and tear the server down) until its 500ms
	// success-page grace period elapses, so this is well within that
	// window — must not re-run the exchange or re-emit a page.
	status2, body2 := hitCallback(t, redirectURI, params)
	if status2 != http.StatusGone {
		t.Errorf("second callback status = %d, want %d", status2, http.StatusGone)
	}
	if body2 != "" {
		t.Errorf("second callback body = %q, want empty", body2)
	}

	res := <-resultCh
	if res.err != nil {
		t.Fatalf("Login: %v", res.err)
	}
	if len(as.TokenRequests) != 1 {
		t.Errorf("TokenRequests = %d, want 1 (a second callback hit must not re-exchange)", len(as.TokenRequests))
	}
}

func TestLogin_NoRegistrationAndNoClientIDErrors(t *testing.T) {
	as := newFakeAS(t)
	as.NoRegistrationEndpoint = true

	called := false
	old := OpenBrowser
	OpenBrowser = func(string) { called = true }
	t.Cleanup(func() { OpenBrowser = old })

	_, err := Login(context.Background(), LoginConfig{ServerURL: as.server.URL}, &syncBuffer{}, LoginOptions{})
	if err == nil {
		t.Fatal("Login: want error when the server has no registration_endpoint and no client id was passed, got nil")
	}
	if !strings.Contains(err.Error(), "--client-id") {
		t.Errorf("Login: err = %v, want it to mention --client-id", err)
	}
	if called {
		t.Error("Login: OpenBrowser should never be called when discovery/registration fails before authorization")
	}
}

func TestLogin_SkipBrowserOpenPrintsURL(t *testing.T) {
	as := newFakeAS(t)

	called := false
	old := OpenBrowser
	OpenBrowser = func(string) { called = true }
	t.Cleanup(func() { OpenBrowser = old })

	ctx, cancel := context.WithCancel(context.Background())
	var out syncBuffer

	resultCh := make(chan error, 1)
	go func() {
		_, err := Login(ctx, LoginConfig{ServerURL: as.server.URL}, &out, LoginOptions{SkipBrowserOpen: true})
		resultCh <- err
	}()

	waitForSubstring(t, &out, "Open this URL to sign in")

	// Nothing ever drives the callback in this test — unblock Login by
	// cancelling instead of waiting out the 5-minute login timeout.
	cancel()
	select {
	case <-resultCh:
	case <-time.After(3 * time.Second):
		t.Fatal("Login did not return after context cancellation")
	}

	if called {
		t.Error("Login: OpenBrowser should never be called when SkipBrowserOpen is set")
	}
	if !strings.Contains(out.String(), as.server.URL) {
		t.Errorf("out = %q, want it to contain the authorize URL", out.String())
	}
}

func TestLogin_ContextCancelled(t *testing.T) {
	as := newFakeAS(t)

	old := OpenBrowser
	OpenBrowser = func(string) {} // never drives the callback
	t.Cleanup(func() { OpenBrowser = old })

	ctx, cancel := context.WithCancel(context.Background())
	var out syncBuffer

	resultCh := make(chan error, 1)
	go func() {
		_, err := Login(ctx, LoginConfig{ServerURL: as.server.URL}, &out, LoginOptions{})
		resultCh <- err
	}()

	waitForSubstring(t, &out, "Open this URL to sign in")
	cancel()

	select {
	case err := <-resultCh:
		if err == nil {
			t.Fatal("Login: want error after context cancellation, got nil")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Login did not return after context cancellation")
	}
}

// TestListenLocal_BindsLoopbackOnly pins the actual bind address, not just
// the redirect_uri string Login constructs (which hardcodes "127.0.0.1"
// independently of what listenLocal actually binds to) — a regression that
// widened the bind host (e.g. to 0.0.0.0) would otherwise survive every
// other Login test untouched.
func TestListenLocal_BindsLoopbackOnly(t *testing.T) {
	ln, err := listenLocal()
	if err != nil {
		t.Fatalf("listenLocal: %v", err)
	}
	defer ln.Close()

	host, _, err := net.SplitHostPort(ln.Addr().String())
	if err != nil {
		t.Fatalf("parsing listener address %q: %v", ln.Addr().String(), err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		t.Errorf("listenLocal bound to %q, want a loopback address", host)
	}
}

// TestBuildGrant_ZeroExpiresInYieldsZeroExpiresAt pins that a token
// response with no expires_in leaves ExpiresAt zero rather than stamping a
// bogus "expires now". A zero ExpiresAt is no longer "never expires": with
// a refresh token present, EnsureFresh now treats it as "unknown, must
// verify on every call" (see refresh_test.go's
// TestEnsureFresh_UnknownExpiryWithRefreshToken_AlwaysVerifies) — this test
// only pins buildGrant's own behavior.
func TestBuildGrant_ZeroExpiresInYieldsZeroExpiresAt(t *testing.T) {
	oldNow := Now
	Now = func() time.Time { return time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC) }
	t.Cleanup(func() { Now = oldNow })

	md := &Metadata{TokenEndpoint: "https://as.example.com/token", RevocationEndpoint: "https://as.example.com/revoke"}
	tok := &Token{AccessToken: "at", RefreshToken: "rt", Scope: "mcp:read", ExpiresIn: 0}

	grant := buildGrant(tok, md, "client-1", "secret-1", "https://mcp.example.com")

	if !grant.ExpiresAt.IsZero() {
		t.Errorf("ExpiresAt = %v, want zero when ExpiresIn is 0", grant.ExpiresAt)
	}
	if grant.AccessToken != "at" || grant.RefreshToken != "rt" || grant.Scope != "mcp:read" {
		t.Errorf("grant = %+v, unexpected token fields", grant)
	}
	if grant.TokenEndpoint != md.TokenEndpoint || grant.RevocationEndpoint != md.RevocationEndpoint {
		t.Errorf("grant = %+v, endpoints not copied from metadata", grant)
	}
	if grant.ClientID != "client-1" || grant.ClientSecret != "secret-1" || grant.Resource != "https://mcp.example.com" {
		t.Errorf("grant = %+v, unexpected identity/resource fields", grant)
	}
}

func TestBuildGrant_PositiveExpiresInStampsExpiresAt(t *testing.T) {
	oldNow := Now
	fixedNow := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	Now = func() time.Time { return fixedNow }
	t.Cleanup(func() { Now = oldNow })

	md := &Metadata{TokenEndpoint: "https://as.example.com/token"}
	tok := &Token{AccessToken: "at", ExpiresIn: 3600}

	grant := buildGrant(tok, md, "client-1", "", "https://mcp.example.com")

	want := fixedNow.Add(3600 * time.Second)
	if !grant.ExpiresAt.Equal(want) {
		t.Errorf("ExpiresAt = %v, want %v", grant.ExpiresAt, want)
	}
}
