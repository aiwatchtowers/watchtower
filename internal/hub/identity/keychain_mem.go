package identity

import (
	"bytes"
	"maps"
	"sync"
)

// MemKeychain is an in-memory Keychain for the tests of other packages
// (the hand-over in hub/adopt): a KeychainStore over it behaves as one over
// the system Keychain — one item per account, each write one call — and
// never touches the disk or the real Keychain.
type MemKeychain struct {
	mu    sync.Mutex
	items map[string][]byte
}

// NewMemKeychainStore returns a KeychainStore for service over a new
// MemKeychain.
func NewMemKeychainStore(service string) (KeychainStore, *MemKeychain) {
	m := &MemKeychain{items: map[string][]byte{}}
	return KeychainStore{Service: service, ops: m}, m
}

// Items is a copy of every item's data, keyed "<service>/<account>".
func (m *MemKeychain) Items() map[string][]byte {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := maps.Clone(m.items)
	for k, v := range out {
		out[k] = bytes.Clone(v)
	}
	return out
}

func (m *MemKeychain) put(service, account string, data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.items[service+"/"+account] = bytes.Clone(data)
	return nil
}

func (m *MemKeychain) get(service, account string, buf []byte) (int, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	data, ok := m.items[service+"/"+account]
	if !ok {
		return 0, false, nil
	}
	if len(data) <= len(buf) {
		copy(buf, data)
	}
	return len(data), true, nil
}

func (m *MemKeychain) del(service, account string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.items, service+"/"+account)
	return nil
}
