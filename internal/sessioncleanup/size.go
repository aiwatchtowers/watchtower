package sessioncleanup

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// errSizeBudget stops a size walk that ran over its budget.
var errSizeBudget = errors.New("size walk over budget")

// sizeReadChunk bounds one directory read: a huge directory is read in
// chunks with the budget and ctx checked between them.
const sizeReadChunk = 256

// DiskSizer is the real Sizer: a du-like walk summing allocated blocks
// (Stat_t.Blocks * 512), not following symlinks, counting a hard-linked
// file once, within the budget (spec §8). Directories are read
// sizeReadChunk entries at a time, so one huge directory cannot run far
// past the budget; a single read stalled on a dead mount still can.
type DiskSizer struct {
	now func() time.Time // nil = time.Now
}

// sizeWalk is one Size call's state.
type sizeWalk struct {
	ctx      context.Context
	now      func() time.Time
	deadline time.Time
	seen     map[[2]uint64]bool
	total    int64
}

// Size is root's allocated bytes; known is false when the walk ran over the
// budget, was cancelled or failed anywhere.
func (s DiskSizer) Size(ctx context.Context, root string, budget time.Duration) (int64, bool) {
	now := s.now
	if now == nil {
		now = time.Now
	}
	w := &sizeWalk{ctx: ctx, now: now, deadline: now().Add(budget), seen: map[[2]uint64]bool{}}
	info, err := os.Lstat(root)
	if err != nil {
		return 0, false
	}
	if err := w.add(fs.FileInfoToDirEntry(info)); err != nil {
		return 0, false
	}
	if info.IsDir() {
		if err := w.walk(root); err != nil {
			return 0, false
		}
	}
	return w.total, true
}

// walk sums every entry under dir, depth first, without following links.
func (w *sizeWalk) walk(dir string) error {
	stack := []string{dir}
	for len(stack) > 0 {
		d := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		subdirs, err := w.readDir(d)
		if err != nil {
			return err
		}
		stack = append(stack, subdirs...)
	}
	return nil
}

// readDir adds dir's entries chunk by chunk and returns its subdirectories.
func (w *sizeWalk) readDir(dir string) ([]string, error) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer f.Close() // read-only directory handle
	var subdirs []string
	for {
		if err := w.inBudget(); err != nil {
			return nil, err
		}
		entries, err := f.ReadDir(sizeReadChunk)
		for _, e := range entries {
			if aerr := w.add(e); aerr != nil {
				return nil, aerr
			}
			if e.IsDir() {
				subdirs = append(subdirs, filepath.Join(dir, e.Name()))
			}
		}
		if errors.Is(err, io.EOF) {
			return subdirs, nil
		}
		if err != nil {
			return nil, err
		}
	}
}

func (w *sizeWalk) inBudget() error {
	if err := w.ctx.Err(); err != nil {
		return err
	}
	if !w.now().Before(w.deadline) {
		return errSizeBudget
	}
	return nil
}

func (w *sizeWalk) add(d fs.DirEntry) error {
	n, err := allocatedBytes(d, w.seen)
	w.total += n
	return err
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
		key := [2]uint64{uint64(st.Dev), uint64(st.Ino)} //nolint:unconvert // dev/ino widths differ per platform
		if seen[key] {
			return 0, nil
		}
		seen[key] = true
	}
	return st.Blocks * 512, nil
}
