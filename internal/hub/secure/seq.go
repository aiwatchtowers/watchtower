package secure

import (
	"fmt"
	"math"
	"sync"
)

// SeqAllocator is a monotonic u64 counter with block reservation: it persists
// ceiling = next + block before handing out a value of a new block, so a crash
// skips ahead and never reuses a seq. Values start at 1; 0 means "none".
type SeqAllocator struct {
	mu      sync.Mutex
	block   uint64
	load    func() (uint64, error)
	store   func(uint64) error
	loaded  bool
	current uint64
	ceiling uint64
}

// NewSeqAllocator takes the block size (0 counts as 1) and the persisted
// ceiling's load and store.
func NewSeqAllocator(block uint64, load func() (uint64, error), store func(uint64) error) *SeqAllocator {
	return &SeqAllocator{block: max(block, 1), load: load, store: store}
}

// Next hands out the next seq; a failed store hands out nothing.
func (a *SeqAllocator) Next() (uint64, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.loaded {
		stored, err := a.load()
		if err != nil {
			return 0, fmt.Errorf("secure: load seq ceiling: %w", err)
		}
		// 0 is reserved as "none" for the rollback guards: the first value is 1.
		a.current = max(stored, 1)
		a.ceiling = stored
		a.loaded = true
	}
	if a.current >= a.ceiling {
		if a.current > math.MaxUint64-a.block {
			return 0, ErrSeqExhausted
		}
		next := a.current + a.block
		if err := a.store(next); err != nil {
			return 0, fmt.Errorf("secure: store seq ceiling: %w", err)
		}
		a.ceiling = next
	}
	v := a.current
	a.current++
	return v, nil
}
