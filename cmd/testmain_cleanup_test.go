package cmd

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// readOnlyHome makes a temp HOME holding a Go module cache as the go tool
// leaves it (every directory 0555, files 0444), the tree os.RemoveAll alone
// cannot delete (#2130). Skipped when the tree would not stop a plain
// removal (root ignores the modes).
func readOnlyHome(t *testing.T, parent, name string) string {
	t.Helper()
	home := filepath.Join(parent, name)
	mod := filepath.Join(home, "go", "pkg", "mod", "example.com", "lib@v1.0.0")
	if err := os.MkdirAll(mod, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(mod, "lib.go")
	if err := os.WriteFile(file, []byte("package lib\n"), 0o444); err != nil {
		t.Fatal(err)
	}
	// Give the tree its write bits back at the end, so a failing or skipped
	// test does not leave t.TempDir a tree it cannot remove.
	t.Cleanup(func() {
		for dir := mod; dir != home; dir = filepath.Dir(dir) {
			_ = os.Chmod(dir, 0o755) // absent when the cleanup under test removed it
		}
	})
	for dir := mod; dir != home; dir = filepath.Dir(dir) {
		if err := os.Chmod(dir, 0o555); err != nil {
			t.Fatal(err)
		}
	}
	if os.Remove(file) == nil {
		t.Skip("a read-only directory does not stop removal here (running as root)")
	}
	return home
}

func assertGone(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("%s still there: %v", path, err)
	}
}

func TestRemoveTestHome_ReadOnlyModuleCache(t *testing.T) {
	home := readOnlyHome(t, t.TempDir(), testHomePrefix+"guard")
	if err := removeTestHome(home); err != nil {
		t.Fatalf("removeTestHome: %v", err)
	}
	assertGone(t, home)
}

func TestRemoveTestHome_MissingIsNoError(t *testing.T) {
	if err := removeTestHome(filepath.Join(t.TempDir(), "gone")); err != nil {
		t.Fatalf("removeTestHome: %v", err)
	}
}

// TestMain's end removes its HOME and keeps the exit code as it was.
func TestFinishTestMain_RemovesHomeKeepsCode(t *testing.T) {
	for _, code := range []int{0, 1} {
		home := readOnlyHome(t, t.TempDir(), testHomePrefix+"finish")
		var stderr bytes.Buffer
		if got := finishTestMain(code, home, &stderr); got != code {
			t.Fatalf("finishTestMain(%d) = %d", code, got)
		}
		assertGone(t, home)
		if stderr.Len() != 0 {
			t.Fatalf("unexpected warning: %s", stderr.String())
		}
	}
}

// A HOME that cannot go is a warning naming what is left, never a red run.
func TestFinishTestMain_LeftoverWarnsKeepsCode(t *testing.T) {
	parent := t.TempDir()
	// A HOME inside a read-only parent: RemoveAll cannot unlink it.
	home := filepath.Join(parent, testHomePrefix+"stuck")
	probe := filepath.Join(parent, "probe")
	for _, dir := range []string{filepath.Join(home, "left"), probe} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(parent, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(parent, 0o700) })
	if os.Remove(probe) == nil {
		t.Skip("a read-only directory does not stop removal here (running as root)")
	}

	var stderr bytes.Buffer
	if got := finishTestMain(0, home, &stderr); got != 0 {
		t.Fatalf("finishTestMain = %d, want 0", got)
	}
	if !bytes.Contains(stderr.Bytes(), []byte("warning")) {
		t.Fatalf("no warning: %q", stderr.String())
	}
}

// A run that died before finishTestMain leaves its HOME; a later run sweeps
// it once it is past the cutoff, and leaves fresh homes (a concurrent run)
// and other names alone.
func TestSweepStaleTestHomes(t *testing.T) {
	parent := t.TempDir()
	now := time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC)
	cutoff := now.Add(-testHomeStaleAge)

	old := readOnlyHome(t, parent, testHomePrefix+"old")
	fresh := filepath.Join(parent, testHomePrefix+"fresh")
	other := filepath.Join(parent, "other-old")
	for _, dir := range []string{fresh, other} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for dir, mtime := range map[string]time.Time{
		old:   now.Add(-25 * time.Hour),
		fresh: now.Add(-time.Hour),
		other: now.Add(-48 * time.Hour),
	} {
		if err := os.Chtimes(dir, mtime, mtime); err != nil {
			t.Fatal(err)
		}
	}

	sweepStaleTestHomes(parent, cutoff)

	assertGone(t, old)
	for _, kept := range []string{fresh, other} {
		if _, err := os.Stat(kept); err != nil {
			t.Fatalf("%s swept: %v", kept, err)
		}
	}
}
