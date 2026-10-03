// Package sample is a neutral fixture for the Go query.
package sample

import "errors"

// MaxItems caps a store.
const MaxItems = 10

const (
	// ModeA is the first mode.
	ModeA = iota
	ModeB
)

var ErrFull = errors.New("full")

var (
	// ErrEmpty is returned by an empty store.
	ErrEmpty       = errors.New("empty")
	lastID, nextID int
)

// ID names a stored item.
type ID = string

type (
	// Count is a plain number.
	Count int
)

// Store keeps items in memory. It is not safe for concurrent use.
type Store struct {
	// items are the stored values.
	items []string
	limit int
}

// Reader reads items.
type Reader interface {
	// Read returns the item at i.
	Read(i int) (string, error)
}

// NewStore returns an empty store.
func NewStore(limit int) *Store {
	return &Store{limit: limit}
}

// Add appends x unless the store is full.
func (s *Store) Add(x string) error {
	if len(s.items) >= s.limit {
		return ErrFull
	}
	s.items = append(s.items, x)
	return nil
}

//go:noinline
func (s Store) Len() int { return len(s.items) }

// Pair holds two values.
//
//go:generate echo pair
type Pair[K comparable, V any] struct {
	Key K
}

func (p *Pair[K, V]) First() K { return p.Key }

func helper[T any](v T) T {
	local := v
	return local
}
