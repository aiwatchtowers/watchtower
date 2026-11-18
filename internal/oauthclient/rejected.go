package oauthclient

import (
	"encoding/json"
	"errors"
)

// ErrClientRejected is a token refresh the vendor refused for the OAuth
// client itself (invalid_client, or unauthorized_client): the company rotated
// the secret or deleted the app, or the grant was issued to a client this
// install no longer uses. Only a new sign-in through the right client fixes
// it, but the person did not revoke the grant: callers record it as status
// 'error' with CodeInvalidClient or CodeUnknownClient
// (db.MarkAccountClientRejected), never 'revoked', so no 72 h purge is scheduled
// (PURGE-01). The Google, Linear and Microsoft refreshers wrap it; Atlassian
// has its own jira.ErrClientRejected with the same codes.
var ErrClientRejected = errors.New("the OAuth client was rejected")

// Account error codes for a rejected client (#1887 P5), stored in the
// account table's error column with status 'error'.
const (
	// CodeInvalidClient: the account is tied to a company bundle — the
	// company changed its app.
	CodeInvalidClient = "invalid_client"
	// CodeUnknownClient: an account on no company — it signed in through an
	// app this install no longer knows.
	CodeUnknownClient = "unknown_client"
)

// IsRejectedBody reports a token-endpoint body that refuses the client:
// {"error":"invalid_client"}, {"error":"unauthorized_client"}, or Google's
// {"error":"deleted_client"}. Decoded JSON only — a proxy page is not the
// vendor's word on the client. Callers ask their invalid_grant check first.
func IsRejectedBody(body []byte) bool {
	var resp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return false
	}
	switch resp.Error {
	case "invalid_client", "unauthorized_client", "deleted_client":
		return true
	}
	return false
}
