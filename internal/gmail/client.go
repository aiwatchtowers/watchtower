package gmail

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// gmailAPIBase is overridable in tests via httptest.Server.
var gmailAPIBase = "https://www.googleapis.com/gmail/v1"

// ErrAuthRevoked is returned when Google reports the refresh token is expired
// or revoked (invalid_grant). It signals that the user must re-authenticate.
var ErrAuthRevoked = errors.New("gmail auth revoked")

// Client wraps Gmail API calls using raw net/http.
// Client is not safe for concurrent use.
type Client struct {
	hc           *http.Client
	accessToken  string
	refreshToken string
	oauthCfg     GoogleOAuthConfig
}

// NewClient creates a Gmail API client.
// It uses the refresh token to obtain a fresh access token.
func NewClient(ctx context.Context, refreshToken string, cfg GoogleOAuthConfig) (*Client, error) {
	c := &Client{
		hc:           &http.Client{Timeout: 30 * time.Second},
		refreshToken: refreshToken,
		oauthCfg:     cfg,
	}
	if err := c.refreshAccessToken(ctx); err != nil {
		return nil, fmt.Errorf("obtaining access token: %w", err)
	}
	return c, nil
}

// isInvalidGrant detects the "invalid_grant" error in Google's token endpoint response body,
// which indicates the refresh token is expired or revoked.
func isInvalidGrant(body []byte) bool {
	var resp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err == nil && resp.Error == "invalid_grant" {
		return true
	}
	return strings.Contains(string(body), "invalid_grant")
}

// refreshAccessToken exchanges the refresh token for a new access token.
func (c *Client) refreshAccessToken(ctx context.Context) error {
	data := url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {c.refreshToken},
		"client_id":     {c.oauthCfg.ClientID},
		"client_secret": {c.oauthCfg.ClientSecret},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, googleTokenEndpoint, strings.NewReader(data.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("token refresh request: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		if isInvalidGrant(body) {
			return fmt.Errorf("%w: %s", ErrAuthRevoked, body)
		}
		return fmt.Errorf("token refresh failed (%d): %s", resp.StatusCode, body)
	}

	var result struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return fmt.Errorf("decoding token response: %w", err)
	}
	c.accessToken = result.AccessToken
	return nil
}

// doGet performs an authenticated GET request to the Gmail API.
func (c *Client) doGet(ctx context.Context, path string, params url.Values) ([]byte, error) {
	return c.doGetRetry(ctx, path, params, false)
}

// doGetRetry is the internal implementation with a retry guard to prevent infinite recursion.
func (c *Client) doGetRetry(ctx context.Context, path string, params url.Values, retried bool) ([]byte, error) {
	u := gmailAPIBase + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.accessToken)

	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("gmail GET %s: %w", path, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading response: %w", err)
	}

	if resp.StatusCode == http.StatusUnauthorized && !retried {
		if err := c.refreshAccessToken(ctx); err != nil {
			return nil, fmt.Errorf("token refresh on 401: %w", err)
		}
		return c.doGetRetry(ctx, path, params, true)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("gmail GET %s (%d): %s", path, resp.StatusCode, body)
	}
	return body, nil
}

// ListInboxMessageIDs returns message IDs matching the Gmail search query
// (e.g. "in:inbox newer_than:7d").
func (c *Client) ListInboxMessageIDs(ctx context.Context, query string, maxResults int) ([]string, error) {
	params := url.Values{"q": {query}, "maxResults": {strconv.Itoa(maxResults)}}
	body, err := c.doGet(ctx, "/users/me/messages", params)
	if err != nil {
		return nil, err
	}
	var resp struct {
		Messages []struct {
			ID string `json:"id"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("decoding list: %w", err)
	}
	ids := make([]string, 0, len(resp.Messages))
	for _, m := range resp.Messages {
		ids = append(ids, m.ID)
	}
	return ids, nil
}

// apiHeader is a single Gmail MIME header (name/value pair).
type apiHeader struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// apiPart is a node in the Gmail MIME tree. Headers only appear on the top-level
// payload, but the type is reused recursively for nested parts.
type apiPart struct {
	MimeType string      `json:"mimeType"`
	Headers  []apiHeader `json:"headers"`
	Body     struct {
		Data string `json:"data"`
	} `json:"body"`
	Parts []apiPart `json:"parts"`
}

// apiMessage is the full-format Gmail message response.
type apiMessage struct {
	ID           string   `json:"id"`
	ThreadID     string   `json:"threadId"`
	LabelIDs     []string `json:"labelIds"`
	Snippet      string   `json:"snippet"`
	InternalDate string   `json:"internalDate"` // unix millis, as string
	Payload      apiPart  `json:"payload"`
}

// GetMessage fetches and parses a single message in full format.
func (c *Client) GetMessage(ctx context.Context, id string) (*Message, error) {
	body, err := c.doGet(ctx, "/users/me/messages/"+id, url.Values{"format": {"full"}})
	if err != nil {
		return nil, err
	}
	var raw apiMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("decoding message: %w", err)
	}

	m := &Message{
		ID:        raw.ID,
		ThreadID:  raw.ThreadID,
		Snippet:   raw.Snippet,
		Labels:    raw.LabelIDs,
		Permalink: "https://mail.google.com/mail/u/0/#inbox/" + raw.ID,
	}
	for _, l := range raw.LabelIDs {
		if l == "UNREAD" {
			m.IsUnread = true
		}
	}
	for _, h := range raw.Payload.Headers {
		switch strings.ToLower(h.Name) {
		case "from":
			m.FromName, m.FromEmail = parseAddress(h.Value)
		case "to":
			m.To = parseAddressList(h.Value)
		case "cc":
			m.Cc = parseAddressList(h.Value)
		case "subject":
			m.Subject = h.Value
		}
	}
	if ms, err := strconv.ParseInt(raw.InternalDate, 10, 64); err == nil {
		m.InternalDate = time.UnixMilli(ms).UTC().Format(time.RFC3339)
	}
	m.BodyText = extractPlainText(raw.Payload)
	return m, nil
}

// extractPlainText walks the MIME tree for the first text/plain body (base64url).
func extractPlainText(p apiPart) string {
	if p.MimeType == "text/plain" && p.Body.Data != "" {
		if dec, err := base64.URLEncoding.DecodeString(p.Body.Data); err == nil {
			return string(dec)
		}
		// Gmail sometimes omits padding; retry with RawURLEncoding.
		if dec, err := base64.RawURLEncoding.DecodeString(p.Body.Data); err == nil {
			return string(dec)
		}
	}
	for _, sub := range p.Parts {
		if txt := extractPlainText(sub); txt != "" {
			return txt
		}
	}
	return ""
}

// parseAddress splits "Name <email>" into (name, email). Falls back to email-only.
func parseAddress(v string) (name, email string) {
	v = strings.TrimSpace(v)
	if i := strings.LastIndex(v, "<"); i >= 0 {
		email = strings.TrimSuffix(strings.TrimSpace(v[i+1:]), ">")
		name = strings.Trim(strings.TrimSpace(v[:i]), `"`)
		return name, strings.TrimSpace(email)
	}
	return "", v
}

// parseAddressList parses a comma-separated address header into emails.
func parseAddressList(v string) []string {
	var out []string
	for _, part := range strings.Split(v, ",") {
		if _, email := parseAddress(part); email != "" {
			out = append(out, email)
		}
	}
	return out
}
