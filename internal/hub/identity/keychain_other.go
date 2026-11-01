//go:build !darwin

package identity

// Off darwin there is no Keychain: every KeychainStore call returns
// ErrNoKeychain and ForDesktopHost always chooses the file store.
const keychainAvailable = false

func keychainPut(string, string, []byte) error         { return ErrNoKeychain }
func keychainGet(string, string, []byte) (bool, error) { return false, ErrNoKeychain }
func keychainDelete(string, string) error              { return ErrNoKeychain }
