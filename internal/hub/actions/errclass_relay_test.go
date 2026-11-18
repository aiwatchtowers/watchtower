package actions

import (
	"fmt"
	"testing"

	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// TestErrClass_RelayAnswers (#1872): the relay's own failure of an op logs as
// relay_internal, and a relay code the transport has no class for logs by
// its code, not as a bare unclassified error.
func TestErrClass_RelayAnswers(t *testing.T) {
	answer := func(c relayv1.ErrorCode, msg string) error {
		return fmt.Errorf("wrapped: %w", relay.MapError(&client.Error{E: &relayv1.Error{Code: c, Message: msg}}))
	}
	for _, c := range []struct {
		err  error
		want string
	}{
		{answer(relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED, "internal error"), "relay_internal"},
		{answer(relayv1.ErrorCode_ERROR_CODE_PAIRING_EXPIRED, ""), "relay_pairing_expired"},
		{answer(relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED, "invalid request"), "relay_unspecified"},
	} {
		if got := errClass(c.err); got != c.want {
			t.Errorf("errClass(%v) = %q, want %q", c.err, got, c.want)
		}
	}
}
