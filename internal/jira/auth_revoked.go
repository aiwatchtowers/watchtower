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
		// The other revoked-grant shape keys on the decoded description ONLY.
		// A bare unauthorized_client (client misconfiguration) is deliberately
		// not revoked, and we never prose-scan the whole body once it decoded
		// cleanly — a misconfiguration's free text could otherwise be misread
		// as a revocation and force a needless re-login.
		return resp.Error == "unauthorized_client" && refreshTokenInvalid(resp.Description)
	}
	// Non-JSON error body (a proxy/WAF page): fall back to the canonical token.
	return strings.Contains(string(body), "invalid_grant")
}

// ErrClientRejected is returned when Atlassian's token endpoint refuses the
// OAuth client itself on a refresh (invalid_client, or an unauthorized_client
// that does not name the refresh token): the company rotated the secret,
// deleted the app, or this account's token was issued by a client this
// install no longer has. Only a new sign-in through the right client fixes
// it, but the person did not revoke the grant: callers record it as status
// 'error' with ClientRejectedCode, never 'revoked', so no 72 h purge is
// scheduled (PURGE-01). Like ErrAuthRevoked it ends the account's pass.
var ErrClientRejected = errors.New("atlassian rejected the OAuth client")

// Account error codes for a rejected client (#1887 P5), stored in
// jira_accounts.error with status 'error'.
const (
	// CodeInvalidClient: the account is tied to a company bundle whose
	// client Atlassian refused — the company changed its app.
	CodeInvalidClient = "invalid_client"
	// CodeUnknownClient: an account on no company whose client is refused
	// or missing — it signed in through an app this install no longer knows.
	CodeUnknownClient = "unknown_client"
)

// ClientRejectedCode is the error code for a rejected client on an account
// tied to companySlug ("" = none).
func ClientRejectedCode(companySlug string) string {
	if companySlug != "" {
		return CodeInvalidClient
	}
	return CodeUnknownClient
}

// isClientRejected reports a token-endpoint body that refuses the client:
// invalid_client, or unauthorized_client (callers ask isInvalidGrant first,
// which takes the unauthorized_client that names the refresh token). Decoded
// JSON only: a proxy page is not Atlassian's word on the client.
func isClientRejected(body []byte) bool {
	var resp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return false
	}
	return resp.Error == "invalid_client" || resp.Error == "unauthorized_client"
}

// accountLost reports an error that ends the account's pass: the grant is
// revoked, or the client is rejected — every remaining request would fail
// the same way.
func accountLost(err error) bool {
	return errors.Is(err, ErrAuthRevoked) || errors.Is(err, ErrClientRejected)
}

// refreshTokenInvalid reports whether text carries Atlassian's "the refresh
// token is invalid" phrasing, in either the underscored or spaced spelling.
func refreshTokenInvalid(s string) bool {
	s = strings.ToLower(s)
	return strings.Contains(s, "refresh_token is invalid") ||
		strings.Contains(s, "refresh token is invalid")
}
