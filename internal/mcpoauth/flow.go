package mcpoauth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"watchtower/internal/auth"
)

// Token is an OAuth 2.0 access/refresh token pair returned by the
// authorization server's token endpoint.
type Token struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	Scope        string `json:"scope"`
	ExpiresIn    int    `json:"expires_in"`
}

// ErrInvalidGrant marks a token endpoint answering invalid_grant: the refresh
// token was revoked or expired and the owner must sign in again.
var ErrInvalidGrant = errors.New("mcpoauth: invalid_grant (sign in again)")

// registerRequest is the RFC 7591 dynamic client registration request body
// Register sends for a public client (no client secret, PKCE-only auth).
type registerRequest struct {
	ClientName              string   `json:"client_name"`
	RedirectURIs            []string `json:"redirect_uris"`
	GrantTypes              []string `json:"grant_types"`
	ResponseTypes           []string `json:"response_types"`
	TokenEndpointAuthMethod string   `json:"token_endpoint_auth_method"`
}

// registerResponse is the subset of the RFC 7591 registration response this
// package needs.
type registerResponse struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret,omitempty"`
}

// tokenErrorResponse is the RFC 6749 §5.2 error body a token endpoint
// returns on a non-2xx response.
type tokenErrorResponse struct {
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

// Register performs RFC 7591 dynamic client registration for a public
// client (token_endpoint_auth_method "none"): the client has no secret and
// relies on PKCE plus the redirect URI to prove it is the party that
// started the flow.
func Register(ctx context.Context, md *Metadata, redirectURI string) (clientID, clientSecret string, err error) {
	if md.RegistrationEndpoint == "" {
		return "", "", fmt.Errorf("mcpoauth: authorization server has no registration_endpoint (dynamic client registration is not supported)")
	}
	if err := requireSecure(md.RegistrationEndpoint); err != nil {
		return "", "", err
	}

	body, err := json.Marshal(registerRequest{
		ClientName:              "Watchtower",
		RedirectURIs:            []string{redirectURI},
		GrantTypes:              []string{"authorization_code", "refresh_token"},
		ResponseTypes:           []string{"code"},
		TokenEndpointAuthMethod: "none",
	})
	if err != nil {
		return "", "", fmt.Errorf("mcpoauth: encoding registration request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, md.RegistrationEndpoint, bytes.NewReader(body))
	if err != nil {
		return "", "", fmt.Errorf("mcpoauth: building registration request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := noRedirectClient.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("mcpoauth: registering client at %s: %w", md.RegistrationEndpoint, err)
	}
	defer resp.Body.Close()

	if isRedirect(resp.StatusCode) {
		return "", "", fmt.Errorf("mcpoauth: registration at %s returned a redirect (status %d); redirects are not followed here", md.RegistrationEndpoint, resp.StatusCode)
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return "", "", fmt.Errorf("mcpoauth: registration at %s failed with status %d", md.RegistrationEndpoint, resp.StatusCode)
	}

	var out registerResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", "", fmt.Errorf("mcpoauth: decoding registration response from %s: %w", md.RegistrationEndpoint, err)
	}
	if out.ClientID == "" {
		return "", "", fmt.Errorf("mcpoauth: registration response from %s is missing client_id", md.RegistrationEndpoint)
	}
	return out.ClientID, out.ClientSecret, nil
}

// AuthorizeURL builds the RFC 6749 authorization request URL: PKCE S256
// challenge, an opaque state value the caller must verify on callback, an
// optional scope, and the RFC 8707 resource indicator naming the MCP server
// this token is for.
func AuthorizeURL(md *Metadata, clientID, redirectURI, state string, pkce auth.PKCEPair, scope, resource string) (string, error) {
	u, err := url.Parse(md.AuthorizationEndpoint)
	if err != nil {
		return "", fmt.Errorf("mcpoauth: parsing authorization_endpoint %q: %w", md.AuthorizationEndpoint, err)
	}

	q := u.Query()
	q.Set("response_type", "code")
	q.Set("client_id", clientID)
	q.Set("redirect_uri", redirectURI)
	q.Set("state", state)
	q.Set("code_challenge", pkce.Challenge)
	q.Set("code_challenge_method", "S256")
	if scope != "" {
		q.Set("scope", scope)
	}
	if resource != "" {
		q.Set("resource", resource)
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

// ExchangeCode redeems an authorization code for a token pair, proving
// possession of the PKCE verifier that matches the challenge sent to
// AuthorizeURL.
func ExchangeCode(ctx context.Context, md *Metadata, clientID, clientSecret, code, redirectURI, codeVerifier, resource string) (*Token, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("client_id", clientID)
	if clientSecret != "" {
		form.Set("client_secret", clientSecret)
	}
	form.Set("code", code)
	form.Set("redirect_uri", redirectURI)
	form.Set("code_verifier", codeVerifier)
	if resource != "" {
		form.Set("resource", resource)
	}
	return postForm(ctx, md.TokenEndpoint, form)
}

// Refresh performs grant_type=refresh_token against tokenEndpoint. A 400
// invalid_grant response (the refresh token was revoked, expired, or
// already rotated away) is reported as ErrInvalidGrant.
func Refresh(ctx context.Context, tokenEndpoint, clientID, clientSecret, refreshToken, resource string) (*Token, error) {
	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("client_id", clientID)
	if clientSecret != "" {
		form.Set("client_secret", clientSecret)
	}
	form.Set("refresh_token", refreshToken)
	if resource != "" {
		form.Set("resource", resource)
	}
	return postForm(ctx, tokenEndpoint, form)
}

// Revoke posts token to the RFC 7009 revocation endpoint. It is
// best-effort: callers should log a failure and move on rather than block
// on it, since the token is being discarded either way.
func Revoke(ctx context.Context, revocationEndpoint, clientID, clientSecret, token string) error {
	if revocationEndpoint == "" {
		return nil
	}
	if err := requireSecure(revocationEndpoint); err != nil {
		return err
	}

	form := url.Values{}
	form.Set("token", token)
	form.Set("client_id", clientID)
	if clientSecret != "" {
		form.Set("client_secret", clientSecret)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, revocationEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return fmt.Errorf("mcpoauth: building revocation request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := noRedirectClient.Do(req)
	if err != nil {
		return fmt.Errorf("mcpoauth: calling revocation endpoint %s: %w", revocationEndpoint, err)
	}
	defer resp.Body.Close()

	if isRedirect(resp.StatusCode) {
		return fmt.Errorf("mcpoauth: revocation endpoint %s returned a redirect (status %d); redirects are not followed here", revocationEndpoint, resp.StatusCode)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("mcpoauth: revocation endpoint %s returned status %d", revocationEndpoint, resp.StatusCode)
	}
	return nil
}

// isRedirect reports whether status is a 3xx response. Both noRedirectClient
// callers below use it: postForm and Register/Revoke's own callers use
// http.Client.CheckRedirect to stop the transport from following, but the
// response itself still carries the 3xx status, and — unlike a transport
// error — must be checked explicitly before falling through to code that
// assumes the body decodes as a token or error JSON payload.
func isRedirect(status int) bool {
	return status >= 300 && status < 400
}

// postForm posts an application/x-www-form-urlencoded body to a token
// endpoint and decodes the resulting token or error response. Shared by
// ExchangeCode and Refresh.
func postForm(ctx context.Context, endpoint string, form url.Values) (*Token, error) {
	if err := requireSecure(endpoint); err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: building token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := noRedirectClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("mcpoauth: calling token endpoint %s: %w", endpoint, err)
	}
	defer resp.Body.Close()

	if isRedirect(resp.StatusCode) {
		return nil, fmt.Errorf("mcpoauth: token endpoint %s returned a redirect (status %d); redirects are not followed here", endpoint, resp.StatusCode)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var tokErr tokenErrorResponse
		if decErr := json.NewDecoder(resp.Body).Decode(&tokErr); decErr != nil {
			return nil, fmt.Errorf("mcpoauth: token endpoint %s returned status %d with an undecodable error body: %w", endpoint, resp.StatusCode, decErr)
		}
		if tokErr.Error == "invalid_grant" {
			return nil, ErrInvalidGrant
		}
		return nil, fmt.Errorf("mcpoauth: token endpoint %s returned error %q: %s", endpoint, tokErr.Error, tokErr.ErrorDescription)
	}

	var tok Token
	if err := json.NewDecoder(resp.Body).Decode(&tok); err != nil {
		return nil, fmt.Errorf("mcpoauth: decoding token response from %s: %w", endpoint, err)
	}
	return &tok, nil
}
