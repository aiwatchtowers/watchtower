package jira

import (
	"encoding/json"
	"errors"
	"strings"
)

// ErrAuthRevoked is returned when Atlassian reports the refresh token is
// expired or revoked (an "invalid_grant" response, or a 403 "unauthorized_client"
// that names the refresh token as invalid — see isInvalidGrant), or when a
// request keeps returning 401 after a successful token refresh. It signals that
// the user must re-consent.
//
// The gmail/calendar precedent (internal/gmail/client.go, internal/calendar/
// client.go): without a distinguishable auth failure a syncer cannot tell
// "this account's grant is gone" from "one project hiccuped", so it has to
// swallow both — which leaves a revoked account showing green in Settings with
// its Re-login button hidden. Syncer.Sync aborts the account's pass on this
// error so phaseJiraSync can record it on the jira_accounts row.
var ErrAuthRevoked = errors.New("jira auth revoked")

// isInvalidGrant detects the two token-endpoint responses Atlassian produces for
// a revoked or expired refresh token: the standard "invalid_grant", and a 403
// "unauthorized_client" whose description says the refresh token itself is
// invalid (observed live as
// {"error":"unauthorized_client","error_description":"refresh_token is invalid"}).
// A bare "unauthorized_client" without that signal is a client misconfiguration
// (wrong client_id/secret), not a revoked grant, so it is deliberately excluded.
// Mirrors gmail.isInvalidGrant: decode first, substring-match as the fallback for
// non-JSON error bodies. Only reached from RefreshToken (grant_type=refresh_token),
// so the whole body is already in a refresh context.
func isInvalidGrant(body []byte) bool {
	var resp struct {
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	if err := json.Unmarshal(body, &resp); err == nil {
		if resp.Error == "invalid_grant" {
			return true
		}
		if resp.Error == "unauthorized_client" && refreshTokenInvalid(resp.Description) {
			return true
		}
	}
	s := string(body)
	return strings.Contains(s, "invalid_grant") || refreshTokenInvalid(s)
}

// refreshTokenInvalid reports whether text carries Atlassian's "the refresh
// token is invalid" phrasing, in either the underscored or spaced spelling.
func refreshTokenInvalid(s string) bool {
	s = strings.ToLower(s)
	return strings.Contains(s, "refresh_token is invalid") ||
		strings.Contains(s, "refresh token is invalid")
}
