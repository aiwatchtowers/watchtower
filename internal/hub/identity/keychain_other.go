//go:build !darwin

package identity

// Off darwin there is no Keychain: every KeychainStore call returns
// ErrNoKeychain and ForDesktopHost always chooses the file store.
const keychainAvailable = false

type systemKeychain struct{}

func (systemKeychain) put(string, string, []byte) error { return ErrNoKeychain }
func (systemKeychain) get(string, string, []byte) (int, bool, error) {
	return 0, false, ErrNoKeychain
}
func (systemKeychain) del(string, string) error { return ErrNoKeychain }
