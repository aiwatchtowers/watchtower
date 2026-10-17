package linear

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"
)

var graphqlEndpoint = "https://api.linear.app/graphql"

// ErrRateLimited means Linear's request or complexity budget is exhausted and
// the reset is too far away to wait for. The syncer holds its watermark.
var ErrRateLimited = errors.New("linear rate limited")

const (
	minRequestsRemaining   = 5
	minComplexityRemaining = 20000
	maxGateWait            = 10 * time.Minute
	maxResponseBytes       = 32 << 20
)

// Client is a Linear GraphQL client for one account: bearer auth from the
// token store, single-flight refresh, and a rate-limit gate.
type Client struct {
	endpoint string
	tokenURL string // overrides the package tokenEndpoint when set (tests)
	cfg      OAuthConfig
	store    *TokenStore
	http     *http.Client
	mu       sync.Mutex // held across load-check-refresh-save
	logger   *log.Logger
	gate     rateGate
}

// NewClient creates a client reading and refreshing tokens through store.
func NewClient(cfg OAuthConfig, store *TokenStore) *Client {
	return &Client{
		endpoint: graphqlEndpoint,
		cfg:      cfg,
		store:    store,
		http:     &http.Client{Timeout: 30 * time.Second},
		logger:   log.New(io.Discard, "", 0),
	}
}

// SetLogger sets the logger for diagnostics.
func (c *Client) SetLogger(l *log.Logger) {
	if l != nil {
		c.logger = l
	}
}

func (c *Client) tokenEndpoint() string {
	if c.tokenURL != "" {
		return c.tokenURL
	}
	return tokenEndpoint
}

type gqlResponse struct {
	Data   json.RawMessage `json:"data"`
	Errors []gqlError      `json:"errors"`
}

type gqlError struct {
	Message    string `json:"message"`
	Extensions struct {
		Code string `json:"code"`
	} `json:"extensions"`
}

// classifyGraphQLErrors maps a non-empty errors list: AUTHENTICATION_ERROR is
// an auth failure (retryable once), RATELIMITED wraps ErrRateLimited, anything
// else reports the first message.
func classifyGraphQLErrors(errs []gqlError) (authFailed bool, err error) {
	for _, e := range errs {
		if e.Extensions.Code == "AUTHENTICATION_ERROR" {
			return true, nil
		}
	}
	for _, e := range errs {
		if e.Extensions.Code == "RATELIMITED" {
			return false, fmt.Errorf("%w: %s", ErrRateLimited, e.Message)
		}
	}
	return false, fmt.Errorf("linear graphql: %s", errs[0].Message)
}

// Do runs one GraphQL operation and decodes resp.data into out.
func (c *Client) Do(ctx context.Context, query string, vars map[string]any, out any) error {
	body, err := json.Marshal(map[string]any{"query": query, "variables": vars})
	if err != nil {
		return fmt.Errorf("encoding linear request: %w", err)
	}
	for attempt := 0; ; attempt++ {
		if err := c.gate.wait(ctx); err != nil {
			return err
		}
		access, err := c.getAccessToken(ctx)
		if err != nil {
			return err
		}
		authFailed, err := c.send(ctx, body, access, out)
		if !authFailed {
			return err
		}
		if attempt > 0 {
			return fmt.Errorf("%w: request rejected after token refresh", ErrAuthRevoked)
		}
		if err := c.refreshIfCurrent(ctx, access); err != nil {
			return err
		}
	}
}

// send performs one HTTP round trip. authFailed reports an authentication
// failure (HTTP 401 or AUTHENTICATION_ERROR), which the caller may retry once.
func (c *Client) send(ctx context.Context, body []byte, access string, out any) (authFailed bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+access)
	resp, err := c.http.Do(req) // endpoint is a package var, overridden only by tests
	if err != nil {
		return false, fmt.Errorf("linear request: %w", err)
	}
	defer resp.Body.Close()
	c.gate.record(resp.Header)
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return false, fmt.Errorf("reading linear response: %w", err)
	}
	if resp.StatusCode == http.StatusUnauthorized {
		return true, nil
	}
	var gr gqlResponse
	parseErr := json.Unmarshal(raw, &gr)
	if parseErr == nil && len(gr.Errors) > 0 {
		return classifyGraphQLErrors(gr.Errors)
	}
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("linear graphql: HTTP %d", resp.StatusCode)
	}
	if parseErr != nil {
		return false, fmt.Errorf("parsing linear response: %w", parseErr)
	}
	if out == nil || len(gr.Data) == 0 {
		return false, nil
	}
	if err := json.Unmarshal(gr.Data, out); err != nil {
		return false, fmt.Errorf("decoding linear data: %w", err)
	}
	return false, nil
}

// getAccessToken loads the current token, refreshing if expired.
func (c *Client) getAccessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	token, err := c.store.Load()
	if err != nil {
		return "", fmt.Errorf("loading token: %w", err)
	}
	if !token.IsExpired() {
		return token.AccessToken, nil
	}
	// Expired: refresh under the cross-process lock, re-reading first — another
	// process may have rotated the refresh token while this one waited.
	unlock, err := c.store.Lock(ctx)
	if err != nil {
		return "", err
	}
	defer unlock()
	token, err = c.store.Load()
	if err != nil {
		return "", fmt.Errorf("loading token: %w", err)
	}
	if !token.IsExpired() {
		return token.AccessToken, nil
	}
	return c.refreshAndSave(ctx, token)
}

// refreshIfCurrent refreshes the stored token only if its access token still
// equals usedToken: racing requests that hit the same 401 must not both spend
// the rotating refresh token. c.mu and the file lock make the check atomic
// across goroutines and processes.
func (c *Client) refreshIfCurrent(ctx context.Context, usedToken string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	unlock, err := c.store.Lock(ctx)
	if err != nil {
		return err
	}
	defer unlock()

	token, err := c.store.Load()
	if err != nil {
		return fmt.Errorf("loading token: %w", err)
	}
	if token.AccessToken != usedToken {
		return nil // someone else already refreshed; the retry picks it up
	}
	_, err = c.refreshAndSave(ctx, token)
	return err
}

func (c *Client) refreshAndSave(ctx context.Context, old *Token) (string, error) {
	nt, err := refreshToken(ctx, c.cfg, old.RefreshToken, c.tokenEndpoint())
	if err != nil {
		return "", err
	}
	if nt.Scope == "" {
		nt.Scope = old.Scope
	}
	if err := c.store.Save(nt); err != nil {
		return "", fmt.Errorf("saving refreshed token: %w", err)
	}
	c.logger.Printf("linear: access token refreshed")
	return nt.AccessToken, nil
}

// rateGate remembers the last reported rate-limit state and delays requests
// while a budget is nearly spent.
type rateGate struct {
	mu                  sync.Mutex
	requestsRemaining   int64
	requestsReset       time.Time
	complexityRemaining int64
	complexityReset     time.Time
	haveRequests        bool
	haveComplexity      bool
}

func headerInt(h http.Header, key string) (int64, bool) {
	v, err := strconv.ParseInt(h.Get(key), 10, 64)
	return v, err == nil
}

func (g *rateGate) record(h http.Header) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if rem, ok := headerInt(h, "X-RateLimit-Requests-Remaining"); ok {
		g.requestsRemaining, g.haveRequests = rem, true
		if ms, ok := headerInt(h, "X-RateLimit-Requests-Reset"); ok {
			g.requestsReset = time.UnixMilli(ms)
		}
	}
	if rem, ok := headerInt(h, "X-RateLimit-Complexity-Remaining"); ok {
		g.complexityRemaining, g.haveComplexity = rem, true
		if ms, ok := headerInt(h, "X-RateLimit-Complexity-Reset"); ok {
			g.complexityReset = time.UnixMilli(ms)
		}
	}
}

// wait blocks until the budgets recover, or returns ErrRateLimited when the
// reset is more than maxGateWait away.
func (g *rateGate) wait(ctx context.Context) error {
	g.mu.Lock()
	var reset time.Time
	if g.haveRequests && g.requestsRemaining < minRequestsRemaining {
		reset = g.requestsReset
	}
	if g.haveComplexity && g.complexityRemaining < minComplexityRemaining && g.complexityReset.After(reset) {
		reset = g.complexityReset
	}
	g.mu.Unlock()

	d := time.Until(reset)
	if d <= 0 {
		return nil
	}
	if d > maxGateWait {
		return fmt.Errorf("%w: budget resets in %s", ErrRateLimited, d.Round(time.Second))
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
