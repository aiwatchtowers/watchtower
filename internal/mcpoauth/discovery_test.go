package mcpoauth

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func writeJSON(t *testing.T, w http.ResponseWriter, v any) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		t.Fatalf("encoding test fixture: %v", err)
	}
}

func validASMetadata(issuer string) Metadata {
	return Metadata{
		Issuer:                            issuer,
		AuthorizationEndpoint:             issuer + "/authorize",
		TokenEndpoint:                     issuer + "/token",
		RegistrationEndpoint:              issuer + "/register",
		CodeChallengeMethodsSupported:     []string{"plain", "S256"},
		TokenEndpointAuthMethodsSupported: []string{"none", "client_secret_basic"},
	}
}

// (a) protected-resource present ⇒ issuer taken from authorization_servers[0].
func TestDiscover_ProtectedResourcePointsAtIssuer(t *testing.T) {
	var asServer *httptest.Server
	asServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/.well-known/oauth-authorization-server" {
			http.NotFound(w, r)
			return
		}
		writeJSON(t, w, validASMetadata(asServer.URL))
	}))
	defer asServer.Close()

	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/.well-known/oauth-protected-resource" {
			http.NotFound(w, r)
			return
		}
		writeJSON(t, w, protectedResourceMetadata{AuthorizationServers: []string{asServer.URL}})
	}))
	defer mcpServer.Close()

	got, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if got.AuthorizationEndpoint != asServer.URL+"/authorize" {
		t.Errorf("AuthorizationEndpoint = %q, want issuer from protected-resource metadata", got.AuthorizationEndpoint)
	}
	if got.TokenEndpoint != asServer.URL+"/token" {
		t.Errorf("TokenEndpoint = %q, want issuer from protected-resource metadata", got.TokenEndpoint)
	}
}

// (b) protected-resource 404 ⇒ origin is issuer, AS metadata found (the
// real-world hosted-Atlassian shape verified 2026-09-10).
func TestDiscover_ProtectedResourceMissingFallsBackToOrigin(t *testing.T) {
	var mcpServer *httptest.Server
	mcpServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			writeJSON(t, w, validASMetadata(mcpServer.URL))
		default:
			http.NotFound(w, r)
		}
	}))
	defer mcpServer.Close()

	got, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if got.AuthorizationEndpoint != mcpServer.URL+"/authorize" {
		t.Errorf("AuthorizationEndpoint = %q, want origin-issued endpoint", got.AuthorizationEndpoint)
	}
}

// (c) AS metadata 404 ⇒ openid-configuration used.
func TestDiscover_FallsBackToOpenIDConfiguration(t *testing.T) {
	var mcpServer *httptest.Server
	mcpServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			http.NotFound(w, r)
		case "/.well-known/openid-configuration":
			writeJSON(t, w, validASMetadata(mcpServer.URL))
		default:
			http.NotFound(w, r)
		}
	}))
	defer mcpServer.Close()

	got, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if got.TokenEndpoint != mcpServer.URL+"/token" {
		t.Errorf("TokenEndpoint = %q, want openid-configuration endpoint", got.TokenEndpoint)
	}
}

// Pins fallback order: when oauth-authorization-server succeeds,
// openid-configuration must never be consulted or allowed to win, even
// though it also serves valid (but distinguishable) metadata here.
func TestDiscover_PrefersAuthorizationServerOverOpenIDConfiguration(t *testing.T) {
	var mcpServer *httptest.Server
	mcpServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			writeJSON(t, w, validASMetadata(mcpServer.URL))
		case "/.well-known/openid-configuration":
			meta := validASMetadata(mcpServer.URL)
			meta.TokenEndpoint = mcpServer.URL + "/oidc-token-should-not-be-used"
			writeJSON(t, w, meta)
		default:
			http.NotFound(w, r)
		}
	}))
	defer mcpServer.Close()

	got, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if got.TokenEndpoint != mcpServer.URL+"/token" {
		t.Errorf("TokenEndpoint = %q, want oauth-authorization-server's endpoint (openid-configuration must not win when AS metadata already succeeded)", got.TokenEndpoint)
	}
}

// A non-404 failure fetching AS metadata (e.g. a 500) is a hard error: it
// must never silently fall back to openid-configuration, even when that
// document is present and valid.
func TestDiscover_ASMetadata500_NoFallbackToOpenIDConfiguration(t *testing.T) {
	var mcpServer *httptest.Server
	mcpServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			http.Error(w, "boom", http.StatusInternalServerError)
		case "/.well-known/openid-configuration":
			writeJSON(t, w, validASMetadata(mcpServer.URL))
		default:
			http.NotFound(w, r)
		}
	}))
	defer mcpServer.Close()

	_, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err == nil {
		t.Fatal("Discover: want error, got nil")
	}
	wantURL := mcpServer.URL + "/.well-known/oauth-authorization-server"
	if !strings.Contains(err.Error(), wantURL) {
		t.Errorf("error %q does not name the failing URL %q", err.Error(), wantURL)
	}
	if !strings.Contains(err.Error(), "500") {
		t.Errorf("error %q does not name the status code 500", err.Error())
	}
}

// (d) all 404 ⇒ error text contains each URL tried.
func TestDiscover_AllMissing_ErrorNamesEveryURLTried(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer mcpServer.Close()

	_, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err == nil {
		t.Fatal("Discover: want error, got nil")
	}
	wantURLs := []string{
		mcpServer.URL + "/.well-known/oauth-protected-resource",
		mcpServer.URL + "/.well-known/oauth-authorization-server",
		mcpServer.URL + "/.well-known/openid-configuration",
	}
	for _, u := range wantURLs {
		if !strings.Contains(err.Error(), u) {
			t.Errorf("error %q does not mention tried URL %q", err.Error(), u)
		}
	}
}

// (e) plain-only PKCE ⇒ error mentioning S256.
func TestDiscover_PlainOnlyPKCE_Rejected(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			meta := validASMetadata("")
			meta.CodeChallengeMethodsSupported = []string{"plain"}
			writeJSON(t, w, meta)
		default:
			http.NotFound(w, r)
		}
	}))
	defer mcpServer.Close()

	_, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err == nil {
		t.Fatal("Discover: want error, got nil")
	}
	if !strings.Contains(err.Error(), "S256") {
		t.Errorf("error %q does not mention S256", err.Error())
	}
}

// (f) http://example.com/mcp (non-loopback http) ⇒ error before any request.
// example.com is never dialed here: requireSecure rejects the URL
// synchronously as the very first thing Discover does, so this test would
// hang or fail on DNS/network if that guard were ever bypassed.
func TestDiscover_NonLoopbackHTTP_RejectedBeforeAnyRequest(t *testing.T) {
	_, err := Discover(context.Background(), "http://example.com/mcp")
	if err == nil {
		t.Fatal("Discover: want error, got nil")
	}
	if !strings.Contains(err.Error(), "https") {
		t.Errorf("error %q does not explain the https requirement", err.Error())
	}
}

// (g) ctx cancelled ⇒ error.
func TestDiscover_ContextCancelled(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer mcpServer.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := Discover(ctx, mcpServer.URL+"/mcp")
	if err == nil {
		t.Fatal("Discover: want error, got nil")
	}
}

func TestRequireSecure(t *testing.T) {
	cases := []struct {
		name    string
		url     string
		wantErr bool
	}{
		{"https anywhere ok", "https://mcp.example.com/mcp", false},
		{"http loopback ipv4 ok", "http://127.0.0.1:8080/mcp", false},
		{"http localhost ok", "http://localhost:8080/mcp", false},
		{"http loopback ipv6 ok", "http://[::1]:8080/mcp", false},
		{"http non-loopback rejected", "http://example.com/mcp", true},
		{"malformed url rejected", "://not-a-url", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := requireSecure(tc.url)
			if tc.wantErr && err == nil {
				t.Errorf("requireSecure(%q): want error, got nil", tc.url)
			}
			if !tc.wantErr && err != nil {
				t.Errorf("requireSecure(%q): unexpected error: %v", tc.url, err)
			}
		})
	}
}

func TestIsLoopbackHost(t *testing.T) {
	cases := []struct {
		host string
		want bool
	}{
		{"localhost", true},
		{"127.0.0.1", true},
		{"::1", true},
		{"example.com", false},
		{"0.0.0.0", false},
	}
	for _, tc := range cases {
		if got := isLoopbackHost(tc.host); got != tc.want {
			t.Errorf("isLoopbackHost(%q) = %v, want %v", tc.host, got, tc.want)
		}
	}
}
