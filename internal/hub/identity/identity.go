// Package identity holds the Go hub's long-lived keys (Go hub spec §5, §7,
// §12.2): hub_sig (Ed25519, signs envelopes and keyboxes), hub_kx (X25519,
// hello and relay key agreement), the 32-byte wrap key that seals the
// sidecar's group keys and content columns, and relay_auth (Ed25519, the
// hosted relay login a phone vouches for). On a headless host they live in a
// 0600 file in the hub state dir (FileStore); phase 3 adds the daemon-owned
// Keychain store on darwin. The bridge never holds keys. No key, and no byte
// derived from one, is ever logged.
package identity

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"fmt"
	"strings"
)

// Identity is the hub's key material. The Keyring and transports borrow it;
// whoever loaded it zeroes it when the hub stops.
type Identity struct {
	Signing   ed25519.PrivateKey
	Agreement *ecdh.PrivateKey
	Wrap      [32]byte
	RelayAuth ed25519.PrivateKey
}

// New draws a fresh identity from crypto/rand.
func New() (Identity, error) {
	var seeds [3][32]byte
	defer func() {
		for i := range seeds {
			clear(seeds[i][:])
		}
	}()
	var id Identity
	for i := range seeds {
		if _, err := rand.Read(seeds[i][:]); err != nil {
			return Identity{}, fmt.Errorf("identity: random: %w", err)
		}
	}
	if _, err := rand.Read(id.Wrap[:]); err != nil {
		return Identity{}, fmt.Errorf("identity: random: %w", err)
	}
	return fromSeeds(seeds[0][:], seeds[1][:], id.Wrap, seeds[2][:])
}

// fromSeeds builds an Identity from the raw 32-byte forms: the Ed25519
// seeds and the X25519 scalar (CryptoKit's rawRepresentation of each).
func fromSeeds(signing, agreement []byte, wrap [32]byte, relayAuth []byte) (Identity, error) {
	if len(signing) != ed25519.SeedSize || len(relayAuth) != ed25519.SeedSize {
		return Identity{}, errMalformed
	}
	kx, err := ecdh.X25519().NewPrivateKey(agreement)
	if err != nil {
		return Identity{}, errMalformed
	}
	return Identity{
		Signing:   ed25519.NewKeyFromSeed(signing),
		Agreement: kx,
		Wrap:      wrap,
		RelayAuth: ed25519.NewKeyFromSeed(relayAuth),
	}, nil
}

// Zero clears the key bytes Go lets us reach: both Ed25519 keys and the wrap
// key. The X25519 key's internal copy is not reachable; it is dropped.
func (i *Identity) Zero() {
	clear(i.Signing)
	clear(i.RelayAuth)
	clear(i.Wrap[:])
	i.Signing, i.RelayAuth, i.Agreement = nil, nil, nil
}

// complete reports whether every key is present.
func (i *Identity) complete() bool {
	return len(i.Signing) == ed25519.PrivateKeySize && len(i.RelayAuth) == ed25519.PrivateKeySize && i.Agreement != nil
}

// RelayDeviceID is the hosted relay's device id for a relay_auth public key:
// unpadded lowercase base32 of SHA-256(pub) (relay auth.DeviceID; the
// vendored client's DeviceID replaces this in Task 8).
func RelayDeviceID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(sum[:]))
}
