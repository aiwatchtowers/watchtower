package slackauth

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

// OAuthAccessURL is Slack's token endpoint; a refresh is a grant_type
// refresh_token call to it.
const OAuthAccessURL = "https://slack.com/api/oauth.v2.access"

// refreshExpiryField is the refresh token's lifetime (seconds) if a refresh
// response ever carries one. Slack documents no such field (neither the
// oauth.v2.access reference nor the token-rotation page names it), so in
// practice the token gets slackRefreshTokenDefaultTTL, the 30 days of the
// PKCE changelog (https://docs.slack.dev/changelog/2026/03/30/pkce).
const refreshExpiryField = "refresh_token_expires_in"

// Error codes of oauth.v2.access after which only a new sign-in helps: the
// refresh token is invalid (spent, or past its 30 days), expired, or the
// token was revoked (https://docs.slack.dev/reference/methods/oauth.v2.access).
const (
	codeInvalidRefreshToken = "invalid_refresh_token"
	codeTokenRevoked        = "token_revoked"
	codeTokenExpired        = "token_expired"
)

// maxRefreshResponse caps the bytes read from the refresh response.
const maxRefreshResponse = 1 << 20

// refreshTimeout bounds one refresh call, so a stalled Slack never holds the
// account's lock for long.
const refreshTimeout = 30 * time.Second

// Refreshed is Slack's answer to a refresh.
type Refreshed struct {
	AccessToken string
	// RefreshToken is the rotated refresh token; "" keeps the old one.
	RefreshToken string
	// ExpiresIn and RefreshExpiresIn are seconds from now; 0 when Slack did
	// not say.
	ExpiresIn        int64
	RefreshExpiresIn int64
}

// Refresher trades a refresh token for a new access token. It never sends a
// client secret (the apps use PKCE).
type Refresher func(ctx context.Context, clientID, refreshToken string) (Refreshed, error)

// RefreshError is Slack's refusal of a refresh, by its error code.
type RefreshError struct{ Code string }

func (e *RefreshError) Error() string { return "slack token refresh: " + e.Code }

// IsReloginError reports whether err is a refusal only a new sign-in fixes:
// the refresh token is invalid or expired, or the token was revoked.
func IsReloginError(err error) bool {
	var re *RefreshError
	if !errors.As(err, &re) {
		return false
	}
	return re.Code == codeInvalidRefreshToken || re.Code == codeTokenRevoked || re.Code == codeTokenExpired
}

// NewRefresher returns the real refresher: a form POST of grant_type,
// client_id and refresh_token (no secret) to endpoint (OAuthAccessURL outside
// tests). It never follows a redirect, which would replay the refresh token.
func NewRefresher(client *http.Client, endpoint string) Refresher {
	noRedirects := http.Client{}
	if client != nil {
		noRedirects = *client
	}
	noRedirects.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return func(ctx context.Context, clientID, refreshToken string) (Refreshed, error) {
		form := url.Values{
			"grant_type":    {"refresh_token"},
			"client_id":     {clientID},
			"refresh_token": {refreshToken},
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
		if err != nil {
			return Refreshed{}, fmt.Errorf("slack token refresh: %w", err)
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		resp, err := noRedirects.Do(req)
		if err != nil {
			return Refreshed{}, fmt.Errorf("slack token refresh: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return Refreshed{}, fmt.Errorf("slack token refresh: HTTP %d", resp.StatusCode)
		}
		return decodeRefresh(io.LimitReader(resp.Body, maxRefreshResponse))
	}
}

// DefaultRefresher is NewRefresher on Slack's endpoint with a bounded client.
func DefaultRefresher() Refresher {
	return NewRefresher(&http.Client{Timeout: refreshTimeout}, OAuthAccessURL)
}

// decodeRefresh reads a refresh response. A user token's fields may sit at
// the top level or under authed_user; the latter wins when it carries a token.
func decodeRefresh(r io.Reader) (Refreshed, error) {
	var top map[string]json.RawMessage
	if err := json.NewDecoder(r).Decode(&top); err != nil {
		return Refreshed{}, fmt.Errorf("slack token refresh: decoding the response: %w", err)
	}
	var ok bool
	_ = json.Unmarshal(top["ok"], &ok)
	if !ok {
		var code string
		_ = json.Unmarshal(top["error"], &code)
		if code == "" {
			code = "unknown_error"
		}
		return Refreshed{}, &RefreshError{Code: code}
	}
	fields := top
	if raw, found := top["authed_user"]; found {
		var user map[string]json.RawMessage
		if json.Unmarshal(raw, &user) == nil && len(user["access_token"]) > 0 {
			fields = user
		}
	}
	var out Refreshed
	_ = json.Unmarshal(fields["access_token"], &out.AccessToken)
	_ = json.Unmarshal(fields["refresh_token"], &out.RefreshToken)
	_ = json.Unmarshal(fields["expires_in"], &out.ExpiresIn)
	_ = json.Unmarshal(fields[refreshExpiryField], &out.RefreshExpiresIn)
	if out.AccessToken == "" {
		return Refreshed{}, errors.New("slack token refresh: no access token in the response")
	}
	return out, nil
}
