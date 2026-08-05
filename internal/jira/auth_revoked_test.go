package jira

import (
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
)

// isInvalidGrant must recognise Atlassian's revoked-refresh-token response in
// both the JSON shape and the raw-body fallback, and must NOT fire on ordinary
// transient failures — a false positive would abort a whole account's sync and
// demand a re-login the user does not need.
func TestIsInvalidGrant(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{"json invalid_grant", `{"error":"invalid_grant","error_description":"refresh token is invalid"}`, true},
		{"raw body fallback", `invalid_grant`, true},
		{"non-json wrapper", `<html>invalid_grant</html>`, true},
		{"unrelated oauth error", `{"error":"invalid_scope"}`, false},
		{"server error", `{"error":"server_error"}`, false},
		{"rate limited", `{"message":"too many requests"}`, false},
		{"empty", ``, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, isInvalidGrant([]byte(tc.body)))
		})
	}
}

// The sentinel must survive %w-wrapping, since callers match it with
// errors.Is several frames up (Syncer.Sync → phaseJiraSync).
func TestErrAuthRevokedIsMatchableThroughWrapping(t *testing.T) {
	wrapped := fmt.Errorf("syncing project OPS: %w",
		fmt.Errorf("%w: GET /search returned 401 after token refresh", ErrAuthRevoked))

	assert.True(t, errors.Is(wrapped, ErrAuthRevoked))
	assert.False(t, errors.Is(errors.New("some other failure"), ErrAuthRevoked))
}
