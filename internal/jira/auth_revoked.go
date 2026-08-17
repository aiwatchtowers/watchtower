package jira

import (
	"encoding/json"
	"errors"
	"strings"
)

// ErrAuthRevoked is returned when Atlassian reports the refresh token is
// expired or revoked, or when a request keeps returning 401 after a successful
// token refresh. It signals that the user must re-consent.
//
// The gmail/calendar precedent (internal/gmail/client.go, internal/calendar/
// client.go): without a distinguishable auth failure a syncer cannot tell
// "this account's grant is gone" from "one project hiccuped", so it has to
// swallow both — which leaves a revoked account showing green in Settings with
// its Re-login button hidden. Syncer.Sync aborts the account's pass on this
// error so phaseJiraSync can record it on the jira_accounts row.
var ErrAuthRevoked = errors.New("jira auth revoked")

// isInvalidGrant detects Atlassian's "invalid_grant" token-endpoint response,
// which is what a revoked or expired refresh token produces. Mirrors
// gmail.isInvalidGrant: decode first, substring-match as the fallback for
// non-JSON error bodies.
func isInvalidGrant(body []byte) bool {
	var resp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err == nil && resp.Error == "invalid_grant" {
		return true
	}
	return strings.Contains(string(body), "invalid_grant")
}
