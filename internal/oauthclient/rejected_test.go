package oauthclient

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestIsRejectedBody(t *testing.T) {
	for body, want := range map[string]bool{
		`{"error":"invalid_client"}`:                              true,
		`{"error":"unauthorized_client","error_description":"x"}`: true,
		`{"error":"deleted_client"}`:                              true,
		`{"error":"invalid_grant"}`:                               false,
		`{"error":"server_error"}`:                                false,
		`<html>invalid_client</html>`:                             false,
		``:                                                        false,
	} {
		assert.Equal(t, want, IsRejectedBody([]byte(body)), body)
	}
}
