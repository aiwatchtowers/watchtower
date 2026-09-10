package mcpoauth

import (
	"bytes"
	"context"
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

// driveCallback swaps OpenBrowser to capture the authorize URL and, in a
// background goroutine, GET the redirect_uri with the given code and a
// state derived from the URL's actual state by stateFn — exercising the
// real loopback callback exactly as a browser redirect would, since
// fakeAS's /authorize handler really redirects there.
func driveCallback(t *testing.T, code string, stateFn func(actual string) string) {
	t.Helper()
	old := OpenBrowser
	t.Cleanup(func() { OpenBrowser = old })
	OpenBrowser = func(rawURL string) {
		u, err := url.Parse(rawURL)
		if err != nil {
			t.Errorf("parsing authorize URL: %v", err)
			return
		}
		redirectURI := u.Query().Get("redirect_uri")
		state := stateFn(u.Query().Get("state"))
		go func() {
			cb, err := url.Parse(redirectURI)
			if err != nil {
				return
			}
			q := cb.Query()
			q.Set("code", code)
			q.Set("state", state)
			cb.RawQuery = q.Encode()
			resp, err := http.Get(cb.String())
			if err == nil {
				resp.Body.Close()
			}
		}()
	}
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

func TestLogin_HappyPath(t *testing.T) {
	as := newFakeAS(t)

	oldNow := Now
	fixedNow := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	Now = func() time.Time { return fixedNow }
	t.Cleanup(func() { Now = oldNow })

	driveCallback(t, as.AuthCode, func(actual string) string { return actual })

	var out bytes.Buffer
	grant, err := Login(context.Background(), LoginConfig{ServerURL: as.server.URL}, &out, LoginOptions{})
	if err != nil {
		t.Fatalf("Login: %v", err)
	}

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

	driveCallback(t, as.AuthCode, func(actual string) string { return "wrong-state" })

	_, err := Login(context.Background(), LoginConfig{ServerURL: as.server.URL}, &syncBuffer{}, LoginOptions{})
	if err == nil {
		t.Fatal("Login: want error for a state mismatch, got nil")
	}
	if !strings.Contains(err.Error(), "state mismatch") {
		t.Errorf("Login: err = %v, want it to mention state mismatch", err)
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

func TestLogin_BYOClientIDSkipsRegistration(t *testing.T) {
	as := newFakeAS(t)

	driveCallback(t, as.AuthCode, func(actual string) string { return actual })

	grant, err := Login(context.Background(), LoginConfig{ServerURL: as.server.URL, ClientID: "byo-client-id"}, &syncBuffer{}, LoginOptions{})
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if grant.ClientID != "byo-client-id" {
		t.Errorf("ClientID = %q, want %q", grant.ClientID, "byo-client-id")
	}
	if len(as.RegisterRequests) != 0 {
		t.Errorf("RegisterRequests = %d, want 0 when a BYO client id is passed", len(as.RegisterRequests))
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
