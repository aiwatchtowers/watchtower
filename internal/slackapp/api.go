package slackapp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// API is the part of Slack's Web API the setup uses, all with a
// configuration token (never stored; SLACKFULL-02).
type API interface {
	// Team names the workspace the token belongs to (auth.test).
	Team(ctx context.Context, cfgToken string) (teamID, teamName string, err error)
	// Create makes a new app from m (apps.manifest.create). The response's
	// client secret is never decoded.
	Create(ctx context.Context, cfgToken string, m Manifest) (appID, clientID string, err error)
	// Update replaces appID's manifest with m (apps.manifest.update).
	Update(ctx context.Context, cfgToken, appID string, m Manifest) error
	// Export reads appID's manifest (apps.manifest.export).
	Export(ctx context.Context, cfgToken, appID string) (Manifest, error)
}

// SlackError is an ok:false answer from Slack: Code is Slack's error code,
// Details the invalid_manifest problems ("<code> at <pointer>").
type SlackError struct {
	Method  string
	Code    string
	Details []string
}

func (e *SlackError) Error() string {
	msg := fmt.Sprintf("slack %s: %s", e.Method, e.Code)
	if len(e.Details) > 0 {
		msg += " (" + strings.Join(e.Details, "; ") + ")"
	}
	return msg
}

// DefaultBaseURL is Slack's Web API root.
const DefaultBaseURL = "https://slack.com/api/"

// requestTimeout bounds one Slack call.
const requestTimeout = 30 * time.Second

// maxResponse caps a response body read into memory.
const maxResponse = 1 << 20

// errRedirect refuses every redirect: a Slack Web API call never redirects,
// and following one would resend the configuration token elsewhere.
var errRedirect = errors.New("slack answered with a redirect; refused")

// Client is the real API over HTTP.
type Client struct {
	baseURL string
	http    *http.Client
}

// NewClient returns a Client for baseURL (DefaultBaseURL in production, an
// httptest server in tests). Its HTTP client refuses redirects.
func NewClient(baseURL string) *Client {
	if !strings.HasSuffix(baseURL, "/") {
		baseURL += "/"
	}
	return &Client{
		baseURL: baseURL,
		http: &http.Client{
			Timeout: requestTimeout,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return errRedirect
			},
		},
	}
}

// slackAnswer is the envelope every method shares.
type slackAnswer struct {
	OK     bool   `json:"ok"`
	Error  string `json:"error"`
	Errors []struct {
		Code    string `json:"code"`
		Pointer string `json:"pointer"`
	} `json:"errors"`
}

func (a slackAnswer) err(method string) error {
	if a.OK {
		return nil
	}
	code := a.Error
	if code == "" {
		code = "unknown_error"
	}
	e := &SlackError{Method: method, Code: code}
	for _, d := range a.Errors {
		e.Details = append(e.Details, d.Code+" at "+d.Pointer)
	}
	return e
}

// call POSTs form to method with the token as a bearer header (never in the
// URL or the form), checks Slack's ok flag and decodes the answer into out
// (nil: nothing to read).
func (c *Client) call(ctx context.Context, method, cfgToken string, form url.Values, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+method, strings.NewReader(form.Encode()))
	if err != nil {
		return fmt.Errorf("slack %s: %w", method, err)
	}
	req.Header.Set("Authorization", "Bearer "+cfgToken)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("slack %s: %w", method, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("slack %s: HTTP %d", method, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponse))
	if err != nil {
		return fmt.Errorf("slack %s: reading the answer: %w", method, err)
	}
	// The body is never put in an error: a create answer carries the secret.
	var env slackAnswer
	if err := json.Unmarshal(body, &env); err != nil {
		return fmt.Errorf("slack %s: the answer is not JSON", method)
	}
	if err := env.err(method); err != nil {
		return err
	}
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			return fmt.Errorf("slack %s: unexpected answer shape", method)
		}
	}
	return nil
}

// Team implements API with auth.test.
func (c *Client) Team(ctx context.Context, cfgToken string) (string, string, error) {
	var out struct {
		TeamID string `json:"team_id"`
		Team   string `json:"team"`
	}
	if err := c.call(ctx, "auth.test", cfgToken, url.Values{}, &out); err != nil {
		return "", "", err
	}
	if out.TeamID == "" {
		return "", "", fmt.Errorf("slack auth.test: no team_id in the answer")
	}
	return out.TeamID, out.Team, nil
}

// createAnswer is what Create decodes from apps.manifest.create. It has no
// field for client_secret, signing_secret or verification_token, so the
// decoder drops them (SLACKFULL-02).
type createAnswer struct {
	AppID       string `json:"app_id"`
	Credentials struct {
		ClientID string `json:"client_id"`
	} `json:"credentials"`
}

// Create implements API with apps.manifest.create.
func (c *Client) Create(ctx context.Context, cfgToken string, m Manifest) (string, string, error) {
	raw, err := json.Marshal(m)
	if err != nil {
		return "", "", fmt.Errorf("encoding the slack app manifest: %w", err)
	}
	var out createAnswer
	if err := c.call(ctx, "apps.manifest.create", cfgToken, url.Values{"manifest": {string(raw)}}, &out); err != nil {
		return "", "", err
	}
	if out.AppID == "" || out.Credentials.ClientID == "" {
		return "", "", fmt.Errorf("slack apps.manifest.create: no app_id or client_id in the answer")
	}
	return out.AppID, out.Credentials.ClientID, nil
}

// Update implements API with apps.manifest.update.
func (c *Client) Update(ctx context.Context, cfgToken, appID string, m Manifest) error {
	raw, err := json.Marshal(m)
	if err != nil {
		return fmt.Errorf("encoding the slack app manifest: %w", err)
	}
	return c.call(ctx, "apps.manifest.update", cfgToken,
		url.Values{"app_id": {appID}, "manifest": {string(raw)}}, nil)
}

// Export implements API with apps.manifest.export. A credentials object in
// the answer's manifest is dropped.
func (c *Client) Export(ctx context.Context, cfgToken, appID string) (Manifest, error) {
	var out struct {
		Manifest Manifest `json:"manifest"`
	}
	if err := c.call(ctx, "apps.manifest.export", cfgToken, url.Values{"app_id": {appID}}, &out); err != nil {
		return nil, err
	}
	if out.Manifest == nil {
		return nil, fmt.Errorf("slack apps.manifest.export: no manifest in the answer")
	}
	delete(out.Manifest, "credentials")
	return out.Manifest, nil
}
