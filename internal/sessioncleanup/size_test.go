package sessioncleanup

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func allocated(t *testing.T, paths ...string) int64 {
	t.Helper()
	var total int64
	for _, p := range paths {
		var st syscall.Stat_t
		if err := syscall.Lstat(p, &st); err != nil {
			t.Fatal(err)
		}
		total += st.Blocks * 512
	}
	return total
}

func writeBytes(t *testing.T, path string, n int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, n), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestSize_CountsAllocatedBlocksAndStopsAtBudget(t *testing.T) {
	root := t.TempDir()
	a, b := filepath.Join(root, "a.bin"), filepath.Join(root, "sub", "b.bin")
	writeBytes(t, a, 10_000)
	writeBytes(t, b, 70_000)
	if err := os.Link(b, filepath.Join(root, "b-link.bin")); err != nil {
		t.Fatal(err)
	}
	want := allocated(t, root, a, filepath.Join(root, "sub"), b)
	got, known := DiskSizer{}.Size(context.Background(), root, time.Minute)
	if !known || got != want {
		t.Fatalf("Size = %d (known %v), want %d (hard link counted once)", got, known, want)
	}
	if got < 80_000 {
		t.Fatalf("Size = %d, below the bytes written", got)
	}

	base := time.Now()
	calls := 0
	ticking := DiskSizer{now: func() time.Time {
		calls++
		return base.Add(time.Duration(calls) * time.Second)
	}}
	if n, known := ticking.Size(context.Background(), root, 2*time.Second); known || n != 0 {
		t.Fatalf("over budget: Size = %d, known %v; want unknown", n, known)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, known := (DiskSizer{}).Size(ctx, root, time.Minute); known {
		t.Fatal("cancelled walk reported a known size")
	}
	if _, known := (DiskSizer{}).Size(context.Background(), filepath.Join(root, "missing"), time.Minute); known {
		t.Fatal("missing root reported a known size")
	}
}

func TestSize_DoesNotFollowSymlinks(t *testing.T) {
	outside := t.TempDir()
	writeBytes(t, filepath.Join(outside, "big.bin"), 1<<20)
	root := t.TempDir()
	link := filepath.Join(root, "dep")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	got, known := DiskSizer{}.Size(context.Background(), root, time.Minute)
	if want := allocated(t, root, link); !known || got != want {
		t.Fatalf("Size = %d (known %v), want %d: the link itself, not its target", got, known, want)
	}
}

func TestSize_HugeDirectoryChecksTheBudgetBetweenChunks(t *testing.T) {
	root := t.TempDir()
	for i := range 3 * sizeReadChunk {
		writeBytes(t, filepath.Join(root, fmt.Sprintf("f%04d", i)), 1)
	}
	base := time.Now()
	calls := 0
	clock := func() time.Time {
		calls++
		return base.Add(time.Duration(calls) * time.Second)
	}
	// The deadline is read once, the root's first chunk passes, the second
	// chunk is over: the size is unknown before the directory is done.
	if n, known := (DiskSizer{now: clock}).Size(context.Background(), root, 2*time.Second); known || n != 0 {
		t.Fatalf("over budget mid-directory: Size = %d, known %v; want unknown", n, known)
	}
	if calls != 3 {
		t.Fatalf("clock read %d times, want 3 (deadline, chunk 1, chunk 2)", calls)
	}

	ctx, cancel := context.WithCancel(context.Background())
	reads := 0
	cancelling := DiskSizer{now: func() time.Time {
		if reads++; reads == 3 {
			cancel()
		}
		return base
	}}
	if _, known := cancelling.Size(ctx, root, time.Hour); known {
		t.Fatal("a walk cancelled mid-directory reported a known size")
	}
	cancel()
	if n, known := (DiskSizer{}).Size(context.Background(), root, time.Minute); !known || n < int64(3*sizeReadChunk) {
		t.Fatalf("full walk: Size = %d, known %v", n, known)
	}
}
