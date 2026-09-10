package mcpoauth

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 30 * time.Second}

// Metadata is the RFC 8414 authorization-server document an MCP server points at.
type Metadata struct {
	Issuer                            string   `json:"issuer"`
	AuthorizationEndpoint             string   `json:"authorization_endpoint"`
	TokenEndpoint                     string   `json:"token_endpoint"`
	RegistrationEndpoint              string   `json:"registration_endpoint,omitempty"`
	RevocationEndpoint                string   `json:"revocation_endpoint,omitempty"`
	CodeChallengeMethodsSupported     []string `json:"code_challenge_methods_supported"`
	TokenEndpointAuthMethodsSupported []string `json:"token_endpoint_auth_methods_supported"`
}

// protectedResourceMetadata is the RFC 9728 document a resource server
// (the MCP server itself) publishes to point at its authorization server.
type protectedResourceMetadata struct {
	AuthorizationServers []string `json:"authorization_servers"`
}

// Discover resolves the authorization-server metadata for an MCP server URL:
//  1. GET <origin>/.well-known/oauth-protected-resource → authorization_servers[0] as issuer (RFC 9728);
//     any non-200 here (the document is optional) falls back to treating the origin itself as the issuer.
//  2. else the server origin is the issuer (the hosted Atlassian case: that document is 404)
//  3. GET <issuer>/.well-known/oauth-authorization-server; ONLY a 404 falls back to
//     GET <issuer>/.well-known/openid-configuration — any other non-2xx status (e.g. a 500) is a hard
//     error naming the URL and status, even if openid-configuration would have succeeded.
//
// Requires https (plain http only for loopback hosts) and S256 in code_challenge_methods_supported.
func Discover(ctx context.Context, serverURL string) (*Metadata, error) {
	if err := requireSecure(serverURL); err != nil {
		return nil, err
	}
	origin, err := originOf(serverURL)
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: parsing MCP server URL %q: %w", serverURL, err)
	}

	var tried []string

	prURL := origin + "/.well-known/oauth-protected-resource"
	tried = append(tried, prURL)
	var pr protectedResourceMetadata
	ok, _, err := fetchJSON(ctx, prURL, &pr)
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: fetching protected-resource metadata from %s: %w", prURL, err)
	}

	issuer := origin
	if ok && len(pr.AuthorizationServers) > 0 && pr.AuthorizationServers[0] != "" {
		issuer = pr.AuthorizationServers[0]
	}
	if err := requireSecure(issuer); err != nil {
		return nil, err
	}

	asURL := issuer + "/.well-known/oauth-authorization-server"
	tried = append(tried, asURL)
	var meta Metadata
	metaURL := asURL
	ok, status, err := fetchJSON(ctx, asURL, &meta)
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: fetching authorization-server metadata from %s: %w", asURL, err)
	}
	if !ok && status != http.StatusNotFound {
		return nil, fmt.Errorf("mcpoauth: fetching authorization-server metadata from %s: unexpected status %d", asURL, status)
	}
	if !ok {
		oidcURL := issuer + "/.well-known/openid-configuration"
		tried = append(tried, oidcURL)
		metaURL = oidcURL
		ok, _, err = fetchJSON(ctx, oidcURL, &meta)
		if err != nil {
			return nil, fmt.Errorf("mcpoauth: fetching openid-configuration from %s: %w", oidcURL, err)
		}
	}
	if !ok {
		return nil, fmt.Errorf("mcpoauth: no authorization-server metadata found for %s (tried %s)", serverURL, strings.Join(tried, ", "))
	}

	if meta.AuthorizationEndpoint == "" || meta.TokenEndpoint == "" {
		return nil, fmt.Errorf("mcpoauth: authorization-server metadata from %s is missing authorization_endpoint or token_endpoint", metaURL)
	}
	if !slices.Contains(meta.CodeChallengeMethodsSupported, "S256") {
		return nil, fmt.Errorf("mcpoauth: authorization server at %s does not advertise S256 PKCE support (code_challenge_methods_supported: %v)", issuer, meta.CodeChallengeMethodsSupported)
	}

	return &meta, nil
}

// requireSecure rejects plain http URLs except against a loopback host
// (127.0.0.1, ::1, localhost) — the shape a local httptest server or a
// local callback redirect takes. Every other host must use https.
func requireSecure(rawURL string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("mcpoauth: parsing URL %q: %w", rawURL, err)
	}
	switch u.Scheme {
	case "https":
		return nil
	case "http":
		if isLoopbackHost(u.Hostname()) {
			return nil
		}
	}
	return fmt.Errorf("mcpoauth: %s must use https (plain http is only allowed for loopback hosts)", rawURL)
}

// isLoopbackHost reports whether h (a URL hostname, no port) names the
// local machine: "localhost" or a loopback IP literal (127.0.0.1, ::1).
func isLoopbackHost(h string) bool {
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// originOf returns the scheme+host of rawURL (no path), e.g.
// "https://mcp.example.com" from "https://mcp.example.com/mcp".
func originOf(rawURL string) (string, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", err
	}
	if u.Scheme == "" || u.Host == "" {
		return "", fmt.Errorf("missing scheme or host")
	}
	return u.Scheme + "://" + u.Host, nil
}

// fetchJSON GETs url and decodes a JSON body into out. ok is true only on a
// 200 response with a decodable body; a non-200 status is reported as
// ok=false with the response's status code and a nil error, leaving the
// caller to decide whether that status means "try a fallback URL" or "hard
// error" — a transport error or a malformed 200 body is always a real
// error that aborts discovery.
func fetchJSON(ctx context.Context, url string, out any) (ok bool, status int, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, 0, err
	}
	req.Header.Set("Accept", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return false, 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return false, resp.StatusCode, nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return false, resp.StatusCode, fmt.Errorf("decoding JSON body: %w", err)
	}
	return true, resp.StatusCode, nil
}
