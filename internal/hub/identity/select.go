package identity

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"

	"watchtower/internal/hub/state"
)

// Staging is a Store that can also hold a staged identity, the one the
// Swift hub hands over at adoption (spec §12.2): staged → promoted → the
// Swift copy deleted.
type Staging interface {
	Store
	Staged() (Identity, bool, error)
	SaveStaged(Identity) error
	PromoteStaged() error
	DeleteStaged() error
}

// MetaIdentityStore is the hub_meta key that records a desktop host's
// identity store, once: IdentityStoreKeychain or IdentityStoreFile.
const MetaIdentityStore = "identity_store"

// The recorded identity store values.
const (
	IdentityStoreKeychain = "keychain"
	IdentityStoreFile     = "file"
)

// KeychainBuildFlag is set by a release build to "false" when the real-Mac
// Keychain check (Go hub phase 3, Task 1) failed:
// -ldflags "-X watchtower/internal/hub/identity.KeychainBuildFlag=false".
// The linker's -X sets string variables only, hence the string.
var KeychainBuildFlag = ""

// KeychainUsable tells a desktop host's first hub start whether to choose
// the Keychain store; false (from KeychainBuildFlag) means the file store.
var KeychainUsable = KeychainBuildFlag != "false"

// ForDesktopHost returns a desktop host's identity store. The first call
// records the choice in hub_meta (keychain when keychainWorks and this
// platform has a Keychain, else file); every later call follows the record
// and never re-decides, so an identity is never looked for in the other
// store. dir is the hub dir (the file store's <dir>/identity.key).
func ForDesktopHost(st *state.Store, dir string, keychainWorks bool) (Staging, error) {
	want := IdentityStoreFile
	if keychainWorks && keychainAvailable {
		want = IdentityStoreKeychain
	}
	var chosen string
	err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		v, ok, err := state.MetaTx(tx, MetaIdentityStore)
		if err != nil {
			return err
		}
		if ok {
			chosen = v
			return nil
		}
		chosen = want
		return state.SetMetaTx(tx, MetaIdentityStore, want)
	})
	if err != nil {
		return nil, fmt.Errorf("identity: recording the identity store: %w", err)
	}
	return storeFor(chosen, dir)
}

// DesktopHostChoice is ForDesktopHost without the write: the recorded store
// when hub_meta has one (recorded true), else the one ForDesktopHost would
// record. The key hand-over records its choice only with the adopted
// identity (MetaIdentityStore in the same transaction), so a refused
// hand-over leaves no record.
func DesktopHostChoice(st *state.Store, dir string, keychainWorks bool) (s Staging, kind string, recorded bool, err error) {
	kind, recorded, err = st.Meta(MetaIdentityStore)
	if err != nil {
		return nil, "", false, fmt.Errorf("identity: reading the identity store: %w", err)
	}
	if !recorded {
		kind = IdentityStoreFile
		if keychainWorks && keychainAvailable {
			kind = IdentityStoreKeychain
		}
	}
	s, err = storeFor(kind, dir)
	return s, kind, recorded, err
}

func storeFor(chosen, dir string) (Staging, error) {
	switch chosen {
	case IdentityStoreKeychain:
		if !keychainAvailable {
			return nil, ErrNoKeychain
		}
		return KeychainStore{Service: KeychainService}, nil
	case IdentityStoreFile:
		return FileStore{Path: filepath.Join(dir, FileName)}, nil
	default:
		return nil, fmt.Errorf("identity: unknown recorded identity store %q", chosen)
	}
}
