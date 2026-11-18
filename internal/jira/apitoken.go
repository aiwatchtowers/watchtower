package jira

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/fsutil"
	"watchtower/internal/policy"
)

// An Atlassian API token account (#1887 §4b, D20): the person's own token,
// sent as Basic auth with their Atlassian email, instead of an OAuth grant.
// It never refreshes; a 401 means the token expired or was revoked
// (ErrAPITokenDead), which the caller records as status 'error', never
// 'revoked' (D22), so PURGE-01 schedules no 72 h purge for it.

// AuthKindAPIToken is jira_accounts.auth_kind of an API-token account.
const AuthKindAPIToken = "api_token"

// CodeAPITokenDead is the account error code of a token Atlassian refuses
// (jira_accounts.error with status 'error'): "The API token stopped working
// (expired or revoked) — paste a new one".
const CodeAPITokenDead = "api_token_dead"

// ErrAPITokenDead is a request an API token account made that Atlassian
// answered 401 (not naming a scope): the token expired or was revoked. Like
// ErrAuthRevoked it ends the account's pass, but it is recorded as an error,
// not a revocation (D22).
var ErrAPITokenDead = errors.New("the API token stopped working (expired or revoked) — paste a new one")

// ErrAPITokenForbidden is a request an API token account did not send: the
// organization's policy (AllowAtlassianAPIToken = false) stops API-token
// accounts. Nothing is written about the account (POLICY-03).
var ErrAPITokenForbidden = errors.New("your organization's policy does not allow Atlassian API tokens")

// apiTokenAllowed is the policy check every API-token request makes; a var
// so tests answer it without a profile.
var apiTokenAllowed = func() bool { return policy.Current().AtlassianAPITokenAllowed() }

// apiGatewayRoot is Atlassian's API gateway; a var so tests point the probe
// at an httptest server.
var apiGatewayRoot = "https://api.atlassian.com"

// ScopeError is an API token Atlassian refused for a missing scope (403, or a
// 401 naming a scope): the person must create a token with the listed
// scopes.
type ScopeError struct{ Scope string }

func (e *ScopeError) Error() string {
	return "This token lacks " + e.Scope + " — create one with the listed scopes"
}

// APITokenCreds is what an API-token account's token file holds
// (jira_token_<id>.json, 0600, in place of the OAuth token). Scope is the
// scope string the account uses the token for (JiraScopes, plus
// ConfluenceScopes with Confluence), so the Confluence access checks read it
// as they read an OAuth grant's. Scoped records the kind the token proved to
// be when it was stored: a scoped token calls the API gateway, a classic one
// the site (APITokenBaseURL).
type APITokenCreds struct {
	AuthKind string `json:"auth_kind"`
	Email    string `json:"email"`
	Token    string `json:"api_token"`
	Scoped   bool   `json:"scoped"`
	Scope    string `json:"scope"`
}

// String never shows the token, so a %v of the creds cannot leak it.
func (c APITokenCreds) String() string {
	return fmt.Sprintf("api token for %s (scoped=%t)", c.Email, c.Scoped)
}

// GoString is String for %#v.
func (c APITokenCreds) GoString() string { return c.String() }

// basicAuth is the Authorization header value of c.
func (c APITokenCreds) basicAuth() string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(c.Email+":"+c.Token))
}

// SaveAPIToken writes an API-token account's credentials, atomically and
// 0600, in place of its OAuth token.
func (s *TokenStore) SaveAPIToken(c APITokenCreds) error {
	if c.Email == "" || c.Token == "" {
		return errors.New("an API token needs an email and a token")
	}
	c.AuthKind = AuthKindAPIToken
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("creating token directory: %w", err)
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling api token: %w", err)
	}
	if err := fsutil.WriteFileAtomic(s.path, data, 0o600); err != nil {
		return fmt.Errorf("saving api token: %w", err)
	}
	return nil
}

// LoadAPIToken reads an API-token account's credentials. A file that holds
// no API token (an OAuth token) is an error.
func (s *TokenStore) LoadAPIToken() (APITokenCreds, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return APITokenCreds{}, err
	}
	var c APITokenCreds
	if err := json.Unmarshal(data, &c); err != nil {
		return APITokenCreds{}, fmt.Errorf("parsing api token: %w", err)
	}
	if c.AuthKind != AuthKindAPIToken || c.Email == "" || c.Token == "" {
		return APITokenCreds{}, errors.New("the account's token file holds no API token — paste a new one")
	}
	return c, nil
}

// APITokenBaseURL is the Jira REST root an API token of its kind calls: the
// gateway https://api.atlassian.com/ex/jira/<cloudID> for a scoped token,
// the site itself for a classic one. Spike S1.4 is not answered yet; this
// is the one place that decides it.
func APITokenBaseURL(scoped bool, cloudID, site string) string {
	return apiTokenBase(apiGatewayRoot, "jira", scoped, cloudID, site)
}

// apiTokenBase is APITokenBaseURL for a product ("jira", "confluence") under
// a gateway root. Confluence paths start with /wiki, so the classic root is
// the site for both products.
func apiTokenBase(gateway, product string, scoped bool, cloudID, site string) string {
	if scoped {
		return gateway + "/ex/" + product + "/" + cloudID
	}
	return strings.TrimSuffix(site, "/")
}

// NewAPITokenClient is a Client of an API-token account on site (cloudID),
// reading its credentials from store at every request: a new token pasted
// while a daemon runs is used by the daemon's client at once.
func NewAPITokenClient(cloudID, site string, store *TokenStore) *Client {
	c := NewClient(cloudID, JiraOAuthConfig{}, store)
	c.apiRoot = apiGatewayRoot
	c.apiTokenSite = site
	c.apiTokenCreds = store.LoadAPIToken
	return c
}

// isAPIToken reports an API-token account's client.
func (c *Client) isAPIToken() bool { return c.apiTokenCreds != nil }

// apiTokenRoot is the REST root of product for the stored token's kind. An
// unreadable store reads as classic: the request then fails on the
// credentials read with the real error.
func (c *Client) apiTokenRoot(product string) string {
	creds, err := c.apiTokenCreds()
	return apiTokenBase(c.apiRoot, product, err == nil && creds.Scoped, c.cloudID, c.apiTokenSite)
}

// apiTokenAuth returns the Authorization value of the stored token and the
// credentials it came from; a policy that stops API tokens sends nothing.
func (c *Client) apiTokenAuth() (string, APITokenCreds, error) {
	if !apiTokenAllowed() {
		return "", APITokenCreds{}, ErrAPITokenForbidden
	}
	creds, err := c.apiTokenCreds()
	if err != nil {
		return "", APITokenCreds{}, fmt.Errorf("loading the API token: %w", err)
	}
	return creds.basicAuth(), creds, nil
}

// apiTokenUnauthorized classifies a 401 to an API-token request made with
// used against fullURL. A body naming a scope is the token lacking one (the
// plain *HTTPStatusError, as for OAuth). A token replaced while the request
// was out — other credentials on file now, or a URL of the other kind than
// the token it carried — is no verdict on the stored token: a plain error,
// the next request uses the new one. Otherwise the token is dead. Reads and
// closes resp's body.
func (c *Client) apiTokenUnauthorized(ctx context.Context, resp *http.Response, method, fullURL string, used APITokenCreds) error {
	herr := newHTTPStatusError(resp)
	resp.Body.Close()
	if strings.Contains(strings.ToLower(herr.Body), "scope") {
		return herr
	}
	// Under the token lock, which a re-auth holds while it saves the new
	// token (and marks the account ok only after): either the new token is
	// seen here and nothing is marked, or the dead mark lands first and the
	// re-auth's ok follows it.
	// Without the lock (a cancelled request) nothing is marked: the next
	// request's 401 marks it.
	mark := c.onAPITokenDead != nil
	if c.tokenStore != nil {
		unlock, err := c.tokenStore.Lock(ctx)
		if err != nil {
			mark = false
		} else {
			defer unlock()
		}
	}
	urlScoped := strings.HasPrefix(fullURL, c.apiRoot+"/ex/")
	now, err := c.apiTokenCreds()
	if err == nil && (now != used || urlScoped != used.Scoped) {
		return fmt.Errorf("the API token changed during %s %s; try again: %w", method, fullURL, herr)
	}
	if err != nil {
		// The token file went away (the account removed) or broke while the
		// request was out: no verdict to write on the row.
		mark = false
	}
	if mark {
		c.onAPITokenDead()
	}
	return fmt.Errorf("%w: %s %s returned 401", ErrAPITokenDead, method, fullURL)
}

// SetOnAPITokenDead makes the client call f whenever Atlassian refuses its
// API token (ErrAPITokenDead), whichever consumer made the request — a Jira
// pass, Confluence, the closed-account lookup — so the account is marked
// even when no Jira board is selected (D22).
func (c *Client) SetOnAPITokenDead(f func()) { c.onAPITokenDead = f }

// ProbeAPIToken checks an API token before anything is stored: GET
// /rest/api/3/myself on the site (a classic token), then on the gateway (a
// scoped one). It returns creds with Scoped set to the kind that answered
// and the person it belongs to. When neither answers: a check that could not
// run is returned first, then a refused scope (*ScopeError), then
// ErrAPITokenDead. site must be a
// <name>.atlassian.net site (ValidateAPITokenSite, checked here too) of
// cloudID (TenantInfo): the token goes to it and to the gateway only. hc nil
// uses the client default.
func ProbeAPIToken(ctx context.Context, hc *http.Client, cloudID, site string, creds APITokenCreds) (APITokenCreds, Myself, error) {
	if err := probeSiteCheck(site); err != nil {
		return APITokenCreds{}, Myself{}, err
	}
	creds.AuthKind = AuthKindAPIToken
	// Both kinds are tried before giving up: how the site answers a scoped
	// token (spike S1.4) is not known, so a refusal there is no verdict.
	var deadErr, scopeErr, otherErr error
	for _, scoped := range []bool{false, true} {
		try := creds
		try.Scoped = scoped
		c := NewClient(cloudID, JiraOAuthConfig{}, nil)
		c.apiRoot = apiGatewayRoot
		c.apiTokenSite = site
		c.apiTokenCreds = func() (APITokenCreds, error) { return try, nil }
		if hc != nil {
			c.httpClient = hc
		}
		me, err := c.probeMyself(ctx)
		var se *ScopeError
		switch {
		case err == nil:
			return try, me, nil
		case errors.Is(err, ErrAPITokenDead):
			deadErr = err
		case errors.As(err, &se):
			scopeErr = err
		default:
			otherErr = err
		}
	}
	// A check that could not run says least about the token; then a
	// missing scope (the token is alive); then a refusal.
	for _, err := range []error{otherErr, scopeErr} {
		if err != nil {
			return APITokenCreds{}, Myself{}, err
		}
	}
	return APITokenCreds{}, Myself{}, deadErr
}

// probeSiteCheck is ValidateAPITokenSite; a var so the probe's tests can
// serve the site from a plain httptest server.
var probeSiteCheck = ValidateAPITokenSite

// probeMyselfScope is the scope GET /rest/api/3/myself needs.
const probeMyselfScope = "read:jira-user"

// probeMyself is GetMyself that tells a refused scope from other failures.
func (c *Client) probeMyself(ctx context.Context) (Myself, error) {
	resp, err := c.do(ctx, http.MethodGet, "/rest/api/3/myself", nil)
	if err != nil {
		var herr *HTTPStatusError
		if errors.As(err, &herr) && herr.Status == http.StatusUnauthorized {
			return Myself{}, &ScopeError{Scope: probeMyselfScope}
		}
		return Myself{}, err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusForbidden:
		return Myself{}, &ScopeError{Scope: probeMyselfScope}
	case resp.StatusCode != http.StatusOK:
		return Myself{}, fmt.Errorf("checking the API token: %w", newHTTPStatusError(resp))
	}
	var me Myself
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&me); err != nil {
		return Myself{}, fmt.Errorf("decoding /myself: %w", err)
	}
	if me.AccountID == "" {
		return Myself{}, errors.New("checking the API token: Atlassian named no account")
	}
	return me, nil
}
