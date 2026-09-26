package auth

import (
	"encoding/base64"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewPKCEPair_Format(t *testing.T) {
	pkce, err := NewPKCEPair()
	require.NoError(t, err)

	// RFC 7636: verifier must be 43-128 chars from the unreserved charset.
	assert.GreaterOrEqual(t, len(pkce.Verifier), 43)
	assert.LessOrEqual(t, len(pkce.Verifier), 128)
	for _, r := range pkce.Verifier {
		assert.Contains(t, PKCEVerifierCharset, string(r), "verifier has a non-unreserved char")
	}

	// Challenge must be base64url (no padding) of sha256(verifier).
	assert.NotContains(t, pkce.Challenge, "=")
	assert.NotContains(t, pkce.Challenge, "+")
	assert.NotContains(t, pkce.Challenge, "/")
	decoded, err := base64.RawURLEncoding.DecodeString(pkce.Challenge)
	require.NoError(t, err)
	assert.Len(t, decoded, 32) // sha256 digest size
}

func TestNewPKCEPair_UniquePerCall(t *testing.T) {
	p1, err := NewPKCEPair()
	require.NoError(t, err)
	p2, err := NewPKCEPair()
	require.NoError(t, err)
	assert.NotEqual(t, p1.Verifier, p2.Verifier)
	assert.NotEqual(t, p1.Challenge, p2.Challenge)
}
