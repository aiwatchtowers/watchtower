package identity

import (
	"errors"
	"fmt"
)

// KeychainService is the live hub's Keychain service on a desktop host.
// Probes and tests use another service name, never this one.
const KeychainService = "com.watchtower.hub"

// The four Keychain accounts, one per key (raw 32-byte forms, as in the
// identity file); a staged identity uses "<name>.staged".
var keychainAccounts = [4]string{"hub_sig", "hub_kx", "wrap", "relay_auth"}

const stagedSuffix = ".staged"

var (
	// ErrNoKeychain: this platform has no Keychain store.
	ErrNoKeychain = errors.New("identity: no Keychain on this platform")
	// errMalformedKeychain never names a byte of an item.
	errMalformedKeychain = errors.New("identity: a hub identity Keychain item is malformed")
	// errPartialKeychain: some of the four items exist and some do not.
	errPartialKeychain = errors.New("identity: the hub identity Keychain items are incomplete")
)

// KeychainError is a failed Security call: the operation and its OSStatus,
// never an item's data.
type KeychainError struct {
	Op     string // save | load | delete
	Status int32
}

func (e *KeychainError) Error() string {
	return fmt.Sprintf("identity: keychain %s: OSStatus %d (%s)", e.Op, e.Status, OSStatusClass(e.Status))
}

// OSStatusClass names the Security result codes a hub identity call can
// meet; any other code is "other".
func OSStatusClass(status int32) string {
	switch status {
	case 0:
		return "ok"
	case -25300:
		return "errSecItemNotFound"
	case -25299:
		return "errSecDuplicateItem"
	case -25293:
		return "errSecAuthFailed"
	case -25308:
		return "errSecInteractionNotAllowed"
	case -128:
		return "errSecUserCanceled"
	case -25244:
		return "errSecInvalidOwnerEdit"
	case -34018:
		return "errSecMissingEntitlement"
	case -25291:
		return "errSecNoSuchKeychain"
	case -26275:
		return "errSecDecode"
	default:
		return "other"
	}
}

// KeychainStore keeps the identity in four generic-password items of one
// service in the login keychain, accounts hub_sig, hub_kx, wrap and
// relay_auth, created by this binary with kSecAttrAccessible =
// AfterFirstUnlockThisDeviceOnly and never synchronizable. No call ever
// shows a Keychain prompt: a refusal comes back as a KeychainError.
type KeychainStore struct{ Service string }

// Load reads the identity; ErrNoIdentity when none of the items exists.
func (s KeychainStore) Load() (Identity, error) { return s.load("") }

// Save writes the four items, replacing existing ones.
func (s KeychainStore) Save(id Identity) error { return s.save("", id) }

// Delete removes the four items; missing items are not an error.
func (s KeychainStore) Delete() error { return s.delete("") }

// Staged reads the staged identity; ok is false when none is staged.
func (s KeychainStore) Staged() (Identity, bool, error) {
	id, err := s.load(stagedSuffix)
	if errors.Is(err, ErrNoIdentity) {
		return Identity{}, false, nil
	}
	if err != nil {
		return Identity{}, false, err
	}
	return id, true, nil
}

// SaveStaged writes the staged items ("<name>.staged").
func (s KeychainStore) SaveStaged(id Identity) error { return s.save(stagedSuffix, id) }

// DeleteStaged removes the staged items; missing items are not an error.
func (s KeychainStore) DeleteStaged() error { return s.delete(stagedSuffix) }

// PromoteStaged makes the staged identity the live one: the staged items
// are written to the live accounts, then removed. A crash in between leaves
// both copies equal, so a repeat finishes the same promotion.
func (s KeychainStore) PromoteStaged() error {
	id, ok, err := s.Staged()
	if err != nil {
		return err
	}
	if !ok {
		return ErrNoIdentity
	}
	defer id.Zero()
	if err := s.Save(id); err != nil {
		return err
	}
	return s.DeleteStaged()
}

func (s KeychainStore) load(suffix string) (Identity, error) {
	if !keychainAvailable {
		return Identity{}, ErrNoKeychain
	}
	var raw [4][32]byte
	defer func() {
		for i := range raw {
			clear(raw[i][:])
		}
	}()
	found := 0
	for i, acct := range keychainAccounts {
		ok, err := keychainGet(s.Service, acct+suffix, raw[i][:])
		if err != nil {
			return Identity{}, err
		}
		if ok {
			found++
		}
	}
	switch found {
	case 0:
		return Identity{}, ErrNoIdentity
	case len(keychainAccounts):
		return fromSeeds(raw[0][:], raw[1][:], raw[2], raw[3][:])
	default:
		return Identity{}, errPartialKeychain
	}
}

func (s KeychainStore) save(suffix string, id Identity) error {
	if !keychainAvailable {
		return ErrNoKeychain
	}
	if !id.complete() {
		return errors.New("identity: refusing to save an incomplete identity")
	}
	kx := id.Agreement.Bytes()
	defer clear(kx)
	sig, auth := id.Signing.Seed(), id.RelayAuth.Seed()
	defer clear(sig)
	defer clear(auth)
	wrap := id.Wrap
	defer clear(wrap[:])
	for i, data := range [4][]byte{sig, kx, wrap[:], auth} {
		if err := keychainPut(s.Service, keychainAccounts[i]+suffix, data); err != nil {
			return err
		}
	}
	return nil
}

func (s KeychainStore) delete(suffix string) error {
	if !keychainAvailable {
		return ErrNoKeychain
	}
	for _, acct := range keychainAccounts {
		if err := keychainDelete(s.Service, acct+suffix); err != nil {
			return err
		}
	}
	return nil
}
