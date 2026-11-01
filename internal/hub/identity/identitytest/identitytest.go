// Package identitytest holds test doubles for the hub identity stores. Test
// code only: production code never imports it, so it is not linked into
// the binary.
package identitytest

import (
	"bytes"
	"maps"
	"sync"

	"watchtower/internal/hub/identity"
)

// MemKeychain is an in-memory identity.KeychainOps: a KeychainStore over it
// behaves as one over the system Keychain — one item per account, each
// write one call — and never touches the disk or the real Keychain.
type MemKeychain struct {
	mu    sync.Mutex
	items map[string][]byte
}

// NewKeychainStore returns a KeychainStore for service over a new
// MemKeychain.
func NewKeychainStore(service string) (identity.KeychainStore, *MemKeychain) {
	m := &MemKeychain{items: map[string][]byte{}}
	return identity.NewKeychainStoreWith(service, m), m
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

// Put implements identity.KeychainOps.
func (m *MemKeychain) Put(service, account string, data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.items[service+"/"+account] = bytes.Clone(data)
	return nil
}

// Get implements identity.KeychainOps.
func (m *MemKeychain) Get(service, account string, buf []byte) (int, bool, error) {
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

// Del implements identity.KeychainOps.
func (m *MemKeychain) Del(service, account string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.items, service+"/"+account)
	return nil
}
