package jira

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// Client is an authenticated HTTP client for the Jira Cloud REST API. The
// same client also backs the Confluence API view (confluence_api.go):
// Jira and Confluence share one Atlassian OAuth 2.0 (3LO) grant, one token
// store, and one single-flight refresh guard (see doURL/refreshIfCurrent).
type Client struct {
	cloudID string

	// baseURL is a raw, full override for the Jira API base — a test-only
	// escape hatch predating apiRoot (see makeTestClient in
	// client_more_test.go, whose fixtures assert on exact request paths with
	// no "/ex/jira/<cloudID>" infix). Production clients (NewClient) never
	// set it, so jiraBase() falls through to the apiRoot derivation below.
	baseURL string
	// apiRoot is the Atlassian API root, default "https://api.atlassian.com".
	// A test seam: newTestClient (confluence_api_test.go) overrides it after
	// construction so both jiraBase() and ConfluenceAPI.base() point at one
	// httptest.Server under different product paths.
	apiRoot string
	// tokenURL overrides the OAuth token endpoint for this Client's own
	// refreshes. Empty means "use the package's jiraTokenEndpoint var" (see
	// tokenEndpoint) — the default for both NewClient and every
	// struct-literal test client that predates this field.
	tokenURL string

	oauthCfg    JiraOAuthConfig
	tokenStore  *TokenStore
	httpClient  *http.Client
	rateLimiter *RateLimiter
	logger      *log.Logger
	mu          sync.Mutex
}

// NewClient creates a Jira API client for the given cloud ID.
func NewClient(cloudID string, oauthCfg JiraOAuthConfig, tokenStore *TokenStore) *Client {
	return &Client{
		cloudID:     cloudID,
		apiRoot:     "https://api.atlassian.com",
		oauthCfg:    oauthCfg,
		tokenStore:  tokenStore,
		httpClient:  &http.Client{Timeout: 30 * time.Second},
		rateLimiter: NewRateLimiter(),
		logger:      log.New(os.Stderr, "[jira] ", log.LstdFlags),
	}
}

// jiraBase returns the Jira Cloud REST API root for this client's site:
// https://api.atlassian.com/ex/jira/{cloudID}, unless baseURL overrides it.
func (c *Client) jiraBase() string {
	if c.baseURL != "" {
		return c.baseURL
	}
	return c.apiRoot + "/ex/jira/" + c.cloudID
}

// tokenEndpoint returns the OAuth token endpoint this Client refreshes
// against: tokenURL if a test set one, else the package's jiraTokenEndpoint
// var (read at call time, so the many existing tests that swap
// jiraTokenEndpoint for the duration of one test keep working unchanged).
func (c *Client) tokenEndpoint() string {
	if c.tokenURL != "" {
		return c.tokenURL
	}
	return jiraTokenEndpoint
}

// SetLogger replaces the client's logger.
func (c *Client) SetLogger(l *log.Logger) {
	c.logger = l
}

// jsonAccept is the Accept header every Jira request (and Confluence's
// GetJSON) sends — both are JSON APIs. Download passes "" instead: an
// attachment binary is not JSON, and Confluence's download endpoint should
// not be told to expect it.
const jsonAccept = "application/json"

// do executes an authenticated Jira request against jiraBase()+path,
// expecting a JSON response. See doURL for the retry/refresh/rate-limit
// loop; do is the Jira-base-bound convenience wrapper every existing Jira
// call site uses.
func (c *Client) do(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	return c.doURL(ctx, method, c.jiraBase()+path, body, jsonAccept)
}

// doURL executes an authenticated HTTP request against a caller-supplied full
// URL, with automatic token refresh on 401 and backoff on 429 — each kind
// gets its own 3-retry budget (see doURLWith), so a run of 429s never eats
// into the refresh budget a following 401 needs. body is the raw request
// payload (nil for no body); a fresh io.Reader is built from it on every
// attempt so a retry after a 401 refresh re-sends the full body instead of an
// already-drained reader (which would otherwise turn a transparent retry into
// an empty POST). accept is sent as the Accept header, or omitted entirely
// when empty — Download passes "" so a binary attachment response is never
// asked to look like JSON. Taking a full URL rather than a base-relative path
// is what lets ConfluenceAPI reuse this same loop against a different
// Atlassian product base (see confluence_api.go).
func (c *Client) doURL(ctx context.Context, method, fullURL string, body []byte, accept string) (*http.Response, error) {
	return c.doURLWith(ctx, c.httpClient, method, fullURL, body, accept)
}

// maxRefreshAttempts/maxRateLimitAttempts are doURLWith's independent retry
// budgets for 401 (token refresh) and 429 (rate-limit backoff). They used to
// share one counter, so three 429s ahead of a 401 (the access token expiring
// mid-backoff, for example) left no budget for the 401 to ever refresh —
// attempt 3 landed straight on "returns 401 after token refresh" without a
// refresh having been attempted at all.
const (
	maxRefreshAttempts   = 3
	maxRateLimitAttempts = 3
)

// doURLWith is doURL over a caller-chosen *http.Client (Download uses one
// with a longer whole-request timeout; see downloadHTTPClient).
func (c *Client) doURLWith(ctx context.Context, hc *http.Client, method, fullURL string, body []byte, accept string) (*http.Response, error) {
	refreshAttempts := 0
	rateLimitAttempts := 0

	for {
		if err := c.rateLimiter.Wait(ctx); err != nil {
			return nil, err
		}

		token, err := c.getAccessToken(ctx)
		if err != nil {
			return nil, fmt.Errorf("getting access token: %w", err)
		}

		var rdr io.Reader
		if body != nil {
			rdr = bytes.NewReader(body)
		}
		req, err := http.NewRequestWithContext(ctx, method, fullURL, rdr)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		if accept != "" {
			req.Header.Set("Accept", accept)
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}

		resp, err := hc.Do(req)
		if err != nil {
			return nil, fmt.Errorf("request %s %s: %w", method, fullURL, err)
		}

		if resp.StatusCode == http.StatusUnauthorized {
			immediateErr, shouldRefresh := unauthorizedOutcome(resp, method, fullURL, refreshAttempts)
			if !shouldRefresh {
				return nil, immediateErr
			}
			refreshAttempts++
			if refreshErr := c.refreshIfCurrent(ctx, token); refreshErr != nil {
				return nil, fmt.Errorf("refreshing token after 401: %w", refreshErr)
			}
			continue
		}

		if resp.StatusCode == http.StatusTooManyRequests {
			wait, giveUpErr, giveUp := rateLimitOutcome(resp, rateLimitAttempts, method, fullURL)
			resp.Body.Close()
			if giveUp {
				return nil, giveUpErr
			}
			rateLimitAttempts++
			c.logger.Printf("rate limited, backing off %s (attempt %d)", wait, rateLimitAttempts)
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(wait):
			}
			continue
		}

		return resp, nil
	}
}

// unauthorizedOutcome classifies a 401 response and decides whether
// doURLWith should refresh the token and retry. Atlassian answers a request
// the grant lacks a scope for with 401 "Unauthorized; scope does not match"
// — that grant is alive and only needs re-consent, so a body naming a scope
// always returns immediately (shouldRefresh=false, immediateErr a plain
// *HTTPStatusError; Confluence maps it to needs-consent) — surfacing it
// right away instead of spending a refresh-token rotation (widening the
// cross-process refresh race, see refreshIfCurrent) on every attempt before
// giving up. Any other body means the access token itself was rejected:
// refreshing is worth retrying until refreshAttempts's budget is spent, then
// immediateErr wraps ErrAuthRevoked instead (what lets Sync abort and the
// daemon mark the account for re-login). Reads and closes resp's body.
// Called on every 401, not only the last one doURLWith is willing to retry,
// so a scope error is recognized on the first response instead of only
// after the refresh budget is spent.
func unauthorizedOutcome(resp *http.Response, method, fullURL string, refreshAttempts int) (immediateErr error, shouldRefresh bool) {
	herr := newHTTPStatusError(resp)
	resp.Body.Close()
	if strings.Contains(strings.ToLower(herr.Body), "scope") {
		return herr, false
	}
	if refreshAttempts >= maxRefreshAttempts {
		return fmt.Errorf("%w: %s %s returned 401 after token refresh", ErrAuthRevoked, method, fullURL), false
	}
	return nil, true
}

// rateLimitOutcome decides what doURLWith does with a 429 response: wait
// then retry (giveUp=false, wait set), or stop (giveUp=true, giveUpErr set).
// giveUpErr wraps the 429's own *HTTPStatusError (via newHTTPStatusError) so
// a caller can still tell the exhausted budget was a rate limit rather than
// some other failure. Does not close resp's body — the caller does that
// exactly once regardless of which branch runs.
func rateLimitOutcome(resp *http.Response, rateLimitAttempts int, method, fullURL string) (wait time.Duration, giveUpErr error, giveUp bool) {
	if rateLimitAttempts >= maxRateLimitAttempts {
		return 0, fmt.Errorf("max retries exceeded for %s %s: %w", method, fullURL, newHTTPStatusError(resp)), true
	}
	wait = BackoffDuration(rateLimitAttempts)
	if ra, ok := retryAfterDuration(resp.Header.Get("Retry-After"), time.Now()); ok {
		wait = ra
	}
	return wait, nil, false
}

// getAccessToken loads the current token, refreshing if expired.
func (c *Client) getAccessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	token, err := c.tokenStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading token: %w", err)
	}
	if !token.IsExpired() {
		return token.AccessToken, nil
	}

	// Expired: refresh under the cross-process token lock, re-reading first —
	// another process (the daemon, a `jira`/`confluence` CLI) may have
	// refreshed while this one waited, and refreshing again with the refresh
	// token it already rotated away would fail with invalid_grant.
	unlock, err := c.tokenStore.Lock(ctx)
	if err != nil {
		return "", err
	}
	defer unlock()
	token, err = c.tokenStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading token: %w", err)
	}
	if !token.IsExpired() {
		return token.AccessToken, nil
	}
	newToken, err := refreshTokenAt(ctx, c.oauthCfg, token.RefreshToken, c.tokenEndpoint())
	if err != nil {
		return "", err
	}
	carryOverUnreturnedFields(newToken, token)
	if err := c.tokenStore.Save(newToken); err != nil {
		return "", fmt.Errorf("saving refreshed token: %w", err)
	}
	return newToken.AccessToken, nil
}

// refreshIfCurrent refreshes the stored token only if its access token still
// equals usedToken — the single-flight guard against Atlassian's rotating
// refresh tokens. Two requests racing the same stale access token both land
// on a 401; without this guard both would call refreshTokenAt with the same
// refresh_token, and the loser's call would fail with invalid_grant (the
// winner's refresh already rotated the refresh_token away), which Atlassian
// treats as effectively revoking the grant. Holding c.mu across the whole
// load-check-refresh-save sequence makes "the stored token still equals
// usedToken" an accurate test of "nobody refreshed while I waited for the
// lock" rather than a check-then-act race of its own. The token store's file
// lock extends the same guarantee across processes (daemon + CLI).
func (c *Client) refreshIfCurrent(ctx context.Context, usedToken string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	unlock, err := c.tokenStore.Lock(ctx)
	if err != nil {
		return err
	}
	defer unlock()

	token, err := c.tokenStore.Load()
	if err != nil {
		return fmt.Errorf("loading token: %w", err)
	}
	if token.AccessToken != usedToken {
		// Another goroutine already refreshed while this one waited for the
		// lock (or for the 401 response) — the caller's retry will pick up
		// the already-refreshed token via getAccessToken.
		return nil
	}

	newToken, err := refreshTokenAt(ctx, c.oauthCfg, token.RefreshToken, c.tokenEndpoint())
	if err != nil {
		return err
	}
	carryOverUnreturnedFields(newToken, token)
	if err := c.tokenStore.Save(newToken); err != nil {
		return fmt.Errorf("saving refreshed token: %w", err)
	}
	return nil
}

// carryOverUnreturnedFields fills newToken's RefreshToken/Scope from old
// whenever Atlassian's refresh response omits them — a rotated refresh_token
// is always returned, but Scope is not guaranteed on every response, and an
// empty Scope must not silently make HasConfluenceScopes start reporting
// false for a grant that never actually lost Confluence access.
func carryOverUnreturnedFields(newToken, old *OAuthToken) {
	if newToken.RefreshToken == "" {
		newToken.RefreshToken = old.RefreshToken
	}
	if newToken.Scope == "" {
		newToken.Scope = old.Scope
	}
}

// get performs a GET request and decodes the JSON response into result.
func (c *Client) get(ctx context.Context, path string, result interface{}) error {
	resp, err := c.do(ctx, http.MethodGet, path, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: status %d: %s", path, resp.StatusCode, body)
	}

	if err := json.Unmarshal(body, result); err != nil {
		return fmt.Errorf("decoding GET %s: %w", path, err)
	}
	return nil
}

// getWithQuery performs a GET request with query parameters and decodes the JSON response.
func (c *Client) getWithQuery(ctx context.Context, path string, params url.Values, result interface{}) error {
	if len(params) > 0 {
		path = path + "?" + params.Encode()
	}
	return c.get(ctx, path, result)
}

// SearchIssues executes a JQL search query with cursor-based pagination.
// Pass empty nextPageToken for the first page.
func (c *Client) SearchIssues(ctx context.Context, jql string, maxResults int, nextPageToken string) (*SearchResult, error) {
	params := url.Values{
		"jql":        {jql},
		"maxResults": {fmt.Sprintf("%d", maxResults)},
		"fields":     {strings.Join(searchFields, ",")},
	}
	if nextPageToken != "" {
		params.Set("nextPageToken", nextPageToken)
	}
	var result SearchResult
	if err := c.getWithQuery(ctx, "/rest/api/3/search/jql", params, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

// searchFields lists the issue fields to request from the Jira API.
var searchFields = []string{
	"summary", "description", "issuetype", "status", "assignee", "reporter",
	"priority", "created", "updated", "duedate", "labels", "components",
	"issuelinks", "sprint", "epic", "parent", "resolutiondate", "fixVersions",
	"statuscategorychangedate",
}

// GetIssueComments fetches every comment on an issue, paginating with
// startAt/maxResults=50 (the FetchAllBoards shape) until startAt+len(page) >=
// total. An empty page always stops the loop, guarding against an infinite
// loop if the API ever reports a total larger than it actually returns.
func (c *Client) GetIssueComments(ctx context.Context, key string) ([]IssueComment, error) {
	path := fmt.Sprintf("/rest/api/3/issue/%s/comment", url.PathEscape(key))
	var all []IssueComment
	startAt := 0
	for {
		params := url.Values{
			"startAt":    {fmt.Sprintf("%d", startAt)},
			"maxResults": {"50"},
		}
		var page CommentList
		if err := c.getWithQuery(ctx, path, params, &page); err != nil {
			return nil, fmt.Errorf("fetching comments for %s (startAt=%d): %w", key, startAt, err)
		}

		all = append(all, page.Comments...)
		startAt += len(page.Comments)

		if len(page.Comments) == 0 || startAt >= page.Total {
			break
		}
	}
	return all, nil
}

// GetProjectVersions fetches all fix versions (releases) for a project.
func (c *Client) GetProjectVersions(ctx context.Context, projectKey string) ([]FixVersion, error) {
	path := fmt.Sprintf("/rest/api/3/project/%s/versions", url.PathEscape(projectKey))
	var versions []FixVersion
	if err := c.get(ctx, path, &versions); err != nil {
		return nil, fmt.Errorf("fetching versions for project %s: %w", projectKey, err)
	}
	return versions, nil
}

// GetMyself returns the connecting person's own Atlassian identity. Needs the
// read:jira-user scope, which every Watchtower Jira grant already carries.
func (c *Client) GetMyself(ctx context.Context) (Myself, error) {
	var m Myself
	if err := c.get(ctx, "/rest/api/3/myself", &m); err != nil {
		return Myself{}, fmt.Errorf("fetching myself: %w", err)
	}
	return m, nil
}
