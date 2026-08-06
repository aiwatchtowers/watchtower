package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
)

// PKCEPair is one code_verifier/code_challenge pair for one login attempt.
// The verifier is a per-login secret: hold it in memory for the life of the
// flow, hand it to the token exchange, and never log or persist it.
type PKCEPair struct {
	Verifier  string
	Challenge string
}

// PKCEVerifierCharset is the RFC 7636 "unreserved" character set allowed in a
// code_verifier.
const PKCEVerifierCharset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

// pkceVerifierLen is comfortably within RFC 7636's required 43-128 chars.
const pkceVerifierLen = 64

// NewPKCEPair generates a fresh RFC 7636 code_verifier (43-128 chars from the
// unreserved charset) and its S256 code_challenge. RFC 8252 §8.1 requires
// PKCE for native apps: without it, the only thing protecting a loopback
// redirect's authorization code is the state parameter, which another local
// process racing for the callback port can observe.
func NewPKCEPair() (PKCEPair, error) {
	buf := make([]byte, pkceVerifierLen)
	if _, err := rand.Read(buf); err != nil {
		return PKCEPair{}, fmt.Errorf("generating pkce verifier: %w", err)
	}
	verifier := make([]byte, pkceVerifierLen)
	for i, b := range buf {
		verifier[i] = PKCEVerifierCharset[int(b)%len(PKCEVerifierCharset)]
	}
	sum := sha256.Sum256(verifier)
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	return PKCEPair{Verifier: string(verifier), Challenge: challenge}, nil
}
