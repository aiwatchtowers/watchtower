package planusage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const usageURL = "https://api.anthropic.com/api/oauth/usage"

// HTTPError is a non-200 answer from the usage endpoint.
type HTTPError struct{ Status int }

func (e *HTTPError) Error() string { return fmt.Sprintf("HTTP %d", e.Status) }

// Client GETs the plan usage endpoint.
type Client struct {
	HTTP      *http.Client
	URL       string
	UserAgent string
}

// NewClient returns a client with the 15 s timeout and a versioned User-Agent.
func NewClient(version string) Client {
	return Client{HTTP: &http.Client{Timeout: 15 * time.Second}, URL: usageURL, UserAgent: "watchtower/" + version}
}

// Fetch GETs the usage body. Errors never quote the request (it carries the token).
func (c Client) Fetch(ctx context.Context, token string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.URL, nil)
	if err != nil {
		return nil, errors.New("planusage: building request failed")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("User-Agent", c.UserAgent)
	resp, err := c.HTTP.Do(req) //nolint:gosec // G704: the URL is the fixed Anthropic endpoint (tests override it)
	if err != nil {
		return nil, fmt.Errorf("planusage: request failed: %w", redact(err, token))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, &HTTPError{Status: resp.StatusCode}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("planusage: reading body: %w", err)
	}
	return body, nil
}

// redact strips the token from an error text, keeping the message.
func redact(err error, token string) error {
	if token == "" || !strings.Contains(err.Error(), token) {
		return err
	}
	return errors.New(strings.ReplaceAll(err.Error(), token, "<redacted>"))
}
