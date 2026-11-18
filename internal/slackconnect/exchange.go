package slackconnect

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// OAuthAccessURL is Slack's code-exchange endpoint.
const OAuthAccessURL = "https://slack.com/api/oauth.v2.access"

// maxExchangeResponse caps the bytes read from oauth.v2.access.
const maxExchangeResponse = 1 << 20

// Grant is a user token Slack issued at the end of a flow.
type Grant struct {
	AccessToken  string
	RefreshToken string
	// ExpiresIn and RefreshExpiresIn are seconds from now; 0 when Slack did
	// not say (no token rotation, or no refresh-token lifetime in the
	// response — plan B spike Q9 settles which Slack sends).
	ExpiresIn        int64
	RefreshExpiresIn int64
	ClientID         string
	AppID            string
	TeamID           string
	TeamName         string
	UserID           string
	Scope            string
}

// Exchanger trades an authorization code and its PKCE verifier for a Grant.
// It never sends a client secret.
type Exchanger func(ctx context.Context, clientID, code, verifier, redirectURI string) (Grant, error)

// NewExchanger returns the real exchanger: a form POST of client_id, code,
// code_verifier and redirect_uri to endpoint (OAuthAccessURL outside tests).
// The form shape is provisional until the Slack spike (plan B Task 1, Q3);
// Task 16 finalises it.
func NewExchanger(client *http.Client, endpoint string) Exchanger {
	return func(ctx context.Context, clientID, code, verifier, redirectURI string) (Grant, error) {
		form := url.Values{
			"client_id":     {clientID},
			"code":          {code},
			"code_verifier": {verifier},
			"redirect_uri":  {redirectURI},
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
		if err != nil {
			return Grant{}, fmt.Errorf("slack oauth.v2.access: %w", err)
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		resp, err := client.Do(req)
		if err != nil {
			return Grant{}, fmt.Errorf("slack oauth.v2.access: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return Grant{}, fmt.Errorf("slack oauth.v2.access: HTTP %d", resp.StatusCode)
		}
		var body accessResponse
		if err := json.NewDecoder(io.LimitReader(resp.Body, maxExchangeResponse)).Decode(&body); err != nil {
			return Grant{}, fmt.Errorf("slack oauth.v2.access: decoding the response: %w", err)
		}
		return body.grant(clientID)
	}
}

// DefaultExchanger is NewExchanger on Slack's endpoint with a bounded client,
// so a stalled exchange cannot hang the listener child.
func DefaultExchanger() Exchanger {
	return NewExchanger(&http.Client{Timeout: exchangeTimeout}, OAuthAccessURL)
}

// accessResponse is the part of oauth.v2.access's answer for a user token.
type accessResponse struct {
	OK         bool   `json:"ok"`
	Error      string `json:"error"`
	AppID      string `json:"app_id"`
	AuthedUser struct {
		ID                    string `json:"id"`
		Scope                 string `json:"scope"`
		AccessToken           string `json:"access_token"`
		RefreshToken          string `json:"refresh_token"`
		ExpiresIn             int64  `json:"expires_in"`
		RefreshTokenExpiresIn int64  `json:"refresh_token_expires_in"`
	} `json:"authed_user"`
	Team       *idName `json:"team"`
	Enterprise *idName `json:"enterprise"`
}

type idName struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (a accessResponse) grant(clientID string) (Grant, error) {
	if !a.OK {
		code := a.Error
		if code == "" {
			code = "unknown_error"
		}
		return Grant{}, fmt.Errorf("slack oauth.v2.access: %s", code)
	}
	if a.AuthedUser.AccessToken == "" {
		return Grant{}, errors.New("slack oauth.v2.access: no user token in the response")
	}
	team := a.Team
	if team == nil || team.ID == "" {
		team = a.Enterprise // an org-wide install on Enterprise Grid
	}
	if team == nil {
		team = &idName{}
	}
	return Grant{
		AccessToken:      a.AuthedUser.AccessToken,
		RefreshToken:     a.AuthedUser.RefreshToken,
		ExpiresIn:        a.AuthedUser.ExpiresIn,
		RefreshExpiresIn: a.AuthedUser.RefreshTokenExpiresIn,
		ClientID:         clientID,
		AppID:            a.AppID,
		TeamID:           team.ID,
		TeamName:         team.Name,
		UserID:           a.AuthedUser.ID,
		Scope:            a.AuthedUser.Scope,
	}, nil
}
