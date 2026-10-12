package sessioncleanup

import (
	"context"
	"errors"
	"io/fs"
	"path/filepath"
	"syscall"
	"time"
)

// errSizeBudget stops a size walk that ran over its budget.
var errSizeBudget = errors.New("size walk over budget")

// DiskSizer is the real Sizer: a du-like walk summing allocated blocks
// (Stat_t.Blocks * 512), not following symlinks, counting a hard-linked
// file once, within the budget (spec §8).
type DiskSizer struct {
	now func() time.Time // nil = time.Now
}

// Size is root's allocated bytes; known is false when the walk ran over the
// budget, was cancelled or failed anywhere.
func (s DiskSizer) Size(ctx context.Context, root string, budget time.Duration) (int64, bool) {
	now := s.now
	if now == nil {
		now = time.Now
	}
	deadline := now().Add(budget)
	seen := map[[2]uint64]bool{}
	var total int64
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !now().Before(deadline) {
			return errSizeBudget
		}
		n, err := allocatedBytes(d, seen)
		total += n
		return err
	})
	if err != nil {
		return 0, false
	}
	return total, true
}

// allocatedBytes is one entry's allocated bytes (lstat: a symlink counts as
// itself); a file with several links counts at its first sighting only.
func allocatedBytes(d fs.DirEntry, seen map[[2]uint64]bool) (int64, error) {
	info, err := d.Info()
	if err != nil {
		return 0, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, errors.New("no stat data")
	}
	if !info.IsDir() && st.Nlink > 1 {
		key := [2]uint64{uint64(st.Dev), uint64(st.Ino)} //nolint:gosec,unconvert // dev/ino widths differ per platform
		if seen[key] {
			return 0, nil
		}
		seen[key] = true
	}
	return st.Blocks * 512, nil
}
