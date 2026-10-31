package secure

import (
	"errors"
	"math"
	"testing"
)

func TestSeqAllocator_FirstIsOneAndCeilingPersistsPerBlock(t *testing.T) {
	var stored uint64
	var stores []uint64
	a := NewSeqAllocator(1024, func() (uint64, error) { return stored, nil }, func(v uint64) error {
		stored = v
		stores = append(stores, v)
		return nil
	})
	for want := uint64(1); want <= 1024; want++ {
		got, err := a.Next()
		if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("Next = %d, want %d", got, want)
		}
		if len(stores) != 1 || stores[0] != 1025 {
			t.Fatalf("after %d: stores %v, want [1025]", got, stores)
		}
	}
	got, err := a.Next()
	if err != nil {
		t.Fatal(err)
	}
	if got != 1025 || len(stores) != 2 || stores[1] != 2049 {
		t.Errorf("Next = %d, stores %v", got, stores)
	}

	// A restart resumes at the persisted ceiling: never a reused value.
	b := NewSeqAllocator(1024, func() (uint64, error) { return stored, nil }, func(v uint64) error { stored = v; return nil })
	if got, err := b.Next(); err != nil || got != 2049 || stored != 3073 {
		t.Errorf("after restart Next = %d (%v), stored %d", got, err, stored)
	}
}

func TestSeqAllocator_StoreFailureHandsOutNothing(t *testing.T) {
	boom := errors.New("disk full")
	a := NewSeqAllocator(4, func() (uint64, error) { return 0, nil }, func(uint64) error { return boom })
	if _, err := a.Next(); !errors.Is(err, boom) {
		t.Errorf("Next: %v, want the store error", err)
	}
	c := NewSeqAllocator(4, func() (uint64, error) { return math.MaxUint64 - 1, nil }, func(uint64) error { return nil })
	if _, err := c.Next(); !errors.Is(err, ErrSeqExhausted) {
		t.Errorf("Next near the top: %v, want ErrSeqExhausted", err)
	}
}

func TestCompareVersion_EpochFirst(t *testing.T) {
	cases := []struct {
		se   uint32
		ss   uint64
		e    uint32
		s    uint64
		want Verdict
	}{
		{1, 5, 1, 6, Newer}, {1, 5, 1, 5, Same}, {1, 5, 1, 4, Older}, {1, 5, 2, 1, Newer}, {2, 1, 1, 99, Older},
	}
	for _, c := range cases {
		if got := CompareVersion(c.se, c.ss, c.e, c.s); got != c.want {
			t.Errorf("stored (%d,%d) incoming (%d,%d): %v, want %v", c.se, c.ss, c.e, c.s, got, c.want)
		}
	}
}
