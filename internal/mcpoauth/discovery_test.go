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

// --- B1/B2: redirect-hop and metadata-endpoint scheme enforcement ---

func TestSecureRedirectPolicy(t *testing.T) {
	req := func(rawURL string) *http.Request {
		r, err := http.NewRequest(http.MethodGet, rawURL, nil)
		if err != nil {
			t.Fatalf("NewRequest(%q): %v", rawURL, err)
		}
		return r
	}

	if err := secureRedirectPolicy(req("https://as.example.com/authorize"), nil); err != nil {
		t.Errorf("secureRedirectPolicy: https hop rejected: %v", err)
	}
	if err := secureRedirectPolicy(req("http://127.0.0.1:8080/x"), nil); err != nil {
		t.Errorf("secureRedirectPolicy: loopback http hop rejected: %v", err)
	}
	if err := secureRedirectPolicy(req("http://example.com/evil"), nil); err == nil {
		t.Error("secureRedirectPolicy: want error for a cleartext non-loopback hop, got nil")
	}

	// The 10-hop cap must still apply even though CheckRedirect is now set
	// explicitly (Go's default cap only applies when CheckRedirect is nil).
	via := make([]*http.Request, 10)
	if err := secureRedirectPolicy(req("https://as.example.com/authorize"), via); err == nil {
		t.Error("secureRedirectPolicy: want error after 10 redirects, got nil")
	}
}

// Discover's GET requests must re-validate every redirect hop, not just the
// initial URL: a 302 to a cleartext non-loopback host is rejected, and the
// target is never dialed (proven by the DNS-unresolvable host not hanging
// the test and the error naming the URL).
func TestDiscover_RedirectToCleartextHost_Rejected(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			http.Redirect(w, r, "http://example.com/evil-authorization-server", http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	defer mcpServer.Close()

	_, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err == nil {
		t.Fatal("Discover: want error, got nil")
	}
	if !strings.Contains(err.Error(), "http://example.com/evil-authorization-server") {
		t.Errorf("error %q does not name the rejected redirect target", err.Error())
	}
	if !strings.Contains(err.Error(), "https") {
		t.Errorf("error %q does not explain the https requirement", err.Error())
	}
}

// A redirect across hosts is fine as long as every hop is secure (both test
// servers are loopback here — the point is that Discover follows the
// redirect at all and resolves metadata from the destination, proving the
// CheckRedirect policy doesn't just block everything).
func TestDiscover_RedirectAcrossHosts_Allowed(t *testing.T) {
	var realServer *httptest.Server
	realServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/.well-known/oauth-authorization-server" {
			http.NotFound(w, r)
			return
		}
		writeJSON(t, w, validASMetadata(realServer.URL))
	}))
	defer realServer.Close()

	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			http.Redirect(w, r, realServer.URL+"/.well-known/oauth-authorization-server", http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	defer mcpServer.Close()

	got, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if got.TokenEndpoint != realServer.URL+"/token" {
		t.Errorf("TokenEndpoint = %q, want the redirect destination's metadata", got.TokenEndpoint)
	}
}

// A metadata document whose authorization_endpoint is cleartext must be
// rejected by Discover itself — AuthorizeURL/Login would otherwise send the
// owner's browser (and the PKCE state) to that URL with no further check.
func TestDiscover_RejectsInsecureAuthorizationEndpoint(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			meta := validASMetadata("https://as.example.com")
			meta.AuthorizationEndpoint = "http://evil.example.com/authorize"
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
	if !strings.Contains(err.Error(), "authorization_endpoint") {
		t.Errorf("error %q does not name the offending field", err.Error())
	}
	if !strings.Contains(err.Error(), "http://evil.example.com/authorize") {
		t.Errorf("error %q does not name the offending URL", err.Error())
	}
}

func TestDiscover_RejectsInsecureTokenEndpoint(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			meta := validASMetadata("https://as.example.com")
			meta.TokenEndpoint = "http://evil.example.com/token"
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
	if !strings.Contains(err.Error(), "token_endpoint") {
		t.Errorf("error %q does not name the offending field", err.Error())
	}
	if !strings.Contains(err.Error(), "http://evil.example.com/token") {
		t.Errorf("error %q does not name the offending URL", err.Error())
	}
}

func TestDiscover_RejectsInsecureRegistrationEndpointOnlyWhenPresent(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			meta := validASMetadata("https://as.example.com")
			meta.RegistrationEndpoint = "http://evil.example.com/register"
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
	if !strings.Contains(err.Error(), "registration_endpoint") {
		t.Errorf("error %q does not name the offending field", err.Error())
	}
}

func TestDiscover_RejectsInsecureRevocationEndpointOnlyWhenPresent(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			meta := validASMetadata("https://as.example.com")
			meta.RevocationEndpoint = "http://evil.example.com/revoke"
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
	if !strings.Contains(err.Error(), "revocation_endpoint") {
		t.Errorf("error %q does not name the offending field", err.Error())
	}
}

// A metadata document with no registration_endpoint/revocation_endpoint at
// all (the Atlassian-shaped case) must still succeed — those two fields are
// validated only when non-empty.
func TestDiscover_EmptyOptionalEndpoints_StillSucceeds(t *testing.T) {
	var mcpServer *httptest.Server
	mcpServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			meta := validASMetadata(mcpServer.URL)
			meta.RegistrationEndpoint = ""
			meta.RevocationEndpoint = ""
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
	if got.RegistrationEndpoint != "" || got.RevocationEndpoint != "" {
		t.Errorf("got RegistrationEndpoint=%q RevocationEndpoint=%q, want both empty", got.RegistrationEndpoint, got.RevocationEndpoint)
	}
}

// TestDiscover_OversizedMetadataBody_Rejected pins the I4 fix end to end: a
// hostile (or misbehaving) authorization-server metadata endpoint streaming
// a body over maxResponseBodyBytes is rejected with a clear error rather
// than Discover attempting to read and decode it in full.
func TestDiscover_OversizedMetadataBody_Rejected(t *testing.T) {
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/oauth-protected-resource":
			http.NotFound(w, r)
		case "/.well-known/oauth-authorization-server":
			w.Header().Set("Content-Type", "application/json")
			// Padding whitespace ahead of otherwise-valid JSON so a failure
			// here can only come from the size cap, not a syntax error.
			_, _ = w.Write([]byte(strings.Repeat(" ", maxResponseBodyBytes+1)))
			_, _ = w.Write([]byte(`{"issuer":"x"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer mcpServer.Close()

	_, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err == nil {
		t.Fatal("Discover: want error for an oversized metadata body")
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("err = %v, want an 'exceeds ... byte limit' error", err)
	}
}

// TestWellKnownAuthServerURL pins the RFC 8414 §3.1 construction (M4): the
// well-known segment is inserted BETWEEN the host and any path component of
// the issuer, never simply appended after it.
func TestWellKnownAuthServerURL(t *testing.T) {
	cases := []struct {
		name string
		base string
		want string
	}{
		{"no path", "https://host.example.com", "https://host.example.com/.well-known/oauth-authorization-server"},
		{"with path", "https://host.example.com/tenant1", "https://host.example.com/.well-known/oauth-authorization-server/tenant1"},
		{"path with trailing slash", "https://host.example.com/tenant1/", "https://host.example.com/.well-known/oauth-authorization-server/tenant1"},
		{"multi-segment path", "https://host.example.com/a/b", "https://host.example.com/.well-known/oauth-authorization-server/a/b"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := wellKnownAuthServerURL(c.base, "oauth-authorization-server")
			if err != nil {
				t.Fatalf("wellKnownAuthServerURL(%q): %v", c.base, err)
			}
			if got != c.want {
				t.Errorf("wellKnownAuthServerURL(%q) = %q, want %q", c.base, got, c.want)
			}
		})
	}
}

// TestOpenIDConfigurationURL pins the OIDC Discovery 1.0 construction,
// deliberately different from RFC 8414: the issuer's path is kept in place
// and the well-known segment is appended after it.
func TestOpenIDConfigurationURL(t *testing.T) {
	cases := []struct {
		name   string
		issuer string
		want   string
	}{
		{"no path", "https://host.example.com", "https://host.example.com/.well-known/openid-configuration"},
		{"with path", "https://host.example.com/tenant1", "https://host.example.com/tenant1/.well-known/openid-configuration"},
		{"path with trailing slash", "https://host.example.com/tenant1/", "https://host.example.com/tenant1/.well-known/openid-configuration"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := openIDConfigurationURL(c.issuer)
			if err != nil {
				t.Fatalf("openIDConfigurationURL(%q): %v", c.issuer, err)
			}
			if got != c.want {
				t.Errorf("openIDConfigurationURL(%q) = %q, want %q", c.issuer, got, c.want)
			}
		})
	}
}

// TestDiscover_PathIssuer_UsesRFC8414WellKnownInsertion is the end-to-end
// pin for M4: when the protected-resource document names an issuer with a
// path component, Discover must request the RFC 8414 well-known URL with
// the segment inserted before the path, not appended after it — an
// authorization server whose issuer has a path (a common multi-tenant
// shape) would otherwise 404 forever.
func TestDiscover_PathIssuer_UsesRFC8414WellKnownInsertion(t *testing.T) {
	var asServer *httptest.Server
	asServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantPath := "/.well-known/oauth-authorization-server/tenant1"
		if r.URL.Path != wantPath {
			t.Errorf("AS metadata request path = %q, want %q (RFC 8414 insertion, not append)", r.URL.Path, wantPath)
			http.NotFound(w, r)
			return
		}
		writeJSON(t, w, validASMetadata(asServer.URL+"/tenant1"))
	}))
	defer asServer.Close()

	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/.well-known/oauth-protected-resource" {
			http.NotFound(w, r)
			return
		}
		writeJSON(t, w, protectedResourceMetadata{AuthorizationServers: []string{asServer.URL + "/tenant1"}})
	}))
	defer mcpServer.Close()

	got, err := Discover(context.Background(), mcpServer.URL+"/mcp")
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if got.AuthorizationEndpoint != asServer.URL+"/tenant1/authorize" {
		t.Errorf("AuthorizationEndpoint = %q, want %q", got.AuthorizationEndpoint, asServer.URL+"/tenant1/authorize")
	}
}
