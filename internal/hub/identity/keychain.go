package identity

import (
	"errors"
	"fmt"
)

// KeychainService is the live hub's Keychain service on a desktop host.
// Probes and tests use another service name, never this one (the probe
// refuses every service starting with "com.watchtower").
const KeychainService = "com.watchtower.hub"

// The identity's Keychain accounts: the live identity is one item, the
// staged one another, each holding the whole identity as one blob in the
// identity format (fileMagic with its version byte, then the four raw
// keys), so every write is one atomic SecItemAdd or SecItemUpdate.
const (
	keychainAccount       = "identity"
	keychainStagedAccount = "identity.staged"
)

var (
	// ErrNoKeychain: this platform has no Keychain store.
	ErrNoKeychain = errors.New("identity: no Keychain on this platform")
	// errMalformedKeychain never names a byte of an item.
	errMalformedKeychain = errors.New("identity: the hub identity Keychain item is malformed")
)

// keychainOps is the Keychain seam: the system Keychain in production, a
// map in tests (crash points included).
type keychainOps interface {
	// put adds the item or replaces its data, in one call.
	put(service, account string, data []byte) error
	// get copies the item's data into buf and returns its full length (more
	// than len(buf) means it did not fit and buf is untouched); found is
	// false when the item does not exist.
	get(service, account string, buf []byte) (n int, found bool, err error)
	// del removes the item; a missing item is not an error.
	del(service, account string) error
}

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

// KeychainStore keeps the identity in one generic-password item of the
// login keychain (account "identity"; a staged identity in a second item,
// "identity.staged"), never synchronizable, created by this binary. Items
// are requested with kSecAttrAccessible = AfterFirstUnlockThisDeviceOnly,
// but the file-based login keychain (the only one a binary without a
// keychain-access-groups entitlement reaches) keeps no accessibility class,
// so nothing here relies on it. No call ever shows a Keychain prompt: a
// refusal comes back as a KeychainError.
type KeychainStore struct {
	Service string
	ops     keychainOps // nil = the system Keychain
}

func (s KeychainStore) kc() keychainOps {
	if s.ops != nil {
		return s.ops
	}
	return systemKeychain{}
}

// Load reads the identity; ErrNoIdentity when no item exists. A malformed
// live item is an error, never replaced silently.
func (s KeychainStore) Load() (Identity, error) {
	id, found, err := s.read(keychainAccount)
	if err != nil {
		return Identity{}, err
	}
	if !found {
		return Identity{}, ErrNoIdentity
	}
	return id, nil
}

// Save writes the identity item, replacing an existing one, in one call.
func (s KeychainStore) Save(id Identity) error { return s.write(keychainAccount, id) }

// Delete removes the identity item; a missing item is not an error.
func (s KeychainStore) Delete() error { return s.kc().del(s.Service, keychainAccount) }

// Staged reads the staged identity; ok is false when none is staged or the
// staged item is not a complete, valid identity (SaveStaged overwrites it).
// A failed Keychain call is still an error.
func (s KeychainStore) Staged() (Identity, bool, error) {
	id, found, err := s.read(keychainStagedAccount)
	if errors.Is(err, errMalformedKeychain) {
		return Identity{}, false, nil
	}
	if err != nil || !found {
		return Identity{}, false, err
	}
	return id, true, nil
}

// SaveStaged writes the staged item, overwriting any staged copy.
func (s KeychainStore) SaveStaged(id Identity) error { return s.write(keychainStagedAccount, id) }

// DeleteStaged removes the staged item; a missing item is not an error.
func (s KeychainStore) DeleteStaged() error { return s.kc().del(s.Service, keychainStagedAccount) }

// PromoteStaged makes the staged identity the live one: the live item is
// written from the staged blob (one call), then the staged item is removed.
// A crash in between leaves two equal items: Load already returns the
// promoted identity and a repeat finishes the same promotion. With no valid
// staged item it returns ErrNothingStaged and changes nothing.
func (s KeychainStore) PromoteStaged() error {
	id, ok, err := s.Staged()
	if err != nil {
		return err
	}
	if !ok {
		return ErrNothingStaged
	}
	defer id.Zero()
	if err := s.Save(id); err != nil {
		return err
	}
	return s.DeleteStaged()
}

// read loads one item; found is false when it does not exist.
func (s KeychainStore) read(account string) (Identity, bool, error) {
	// One byte more than a valid blob, so a longer item is malformed, not
	// truncated.
	var buf [fileLen + 1]byte
	defer clear(buf[:])
	n, found, err := s.kc().get(s.Service, account, buf[:])
	if err != nil || !found {
		return Identity{}, false, err
	}
	if n > len(buf) {
		return Identity{}, false, errMalformedKeychain
	}
	id, err := decodeIdentity(buf[:n])
	if err != nil {
		return Identity{}, false, errMalformedKeychain
	}
	return id, true, nil
}

func (s KeychainStore) write(account string, id Identity) error {
	blob, err := encodeIdentity(id)
	if err != nil {
		return err
	}
	defer clear(blob)
	return s.kc().put(s.Service, account, blob)
}
