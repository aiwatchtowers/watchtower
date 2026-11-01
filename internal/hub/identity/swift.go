package identity

import (
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
)

// FromSwift builds the identity the Swift hub hands over at adoption (spec
// §12.2): its hub_sig Ed25519 seed, hub_kx X25519 scalar and 32-byte wrap
// key (CryptoKit's raw forms), with a fresh relay_auth, which the Swift hub
// never had. The inputs are copied; the caller clears them. A wrong length
// or a bad key is an error that names no byte.
func FromSwift(signing, agreement, wrap []byte) (Identity, error) {
	if len(wrap) != 32 {
		return Identity{}, errMalformed
	}
	var relay [ed25519.SeedSize]byte
	defer clear(relay[:])
	if _, err := rand.Read(relay[:]); err != nil {
		return Identity{}, fmt.Errorf("identity: random: %w", err)
	}
	var w [32]byte
	defer clear(w[:])
	copy(w[:], wrap)
	return fromSeeds(signing, agreement, w, relay[:])
}
