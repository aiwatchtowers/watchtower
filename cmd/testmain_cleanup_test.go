package cmd

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// TestMain's temp HOME must not outlive the run (#2130): a `go` run under
// it leaves a read-only module cache that os.RemoveAll alone cannot delete.
func TestRemoveTestHome_ReadOnlyModuleCache(t *testing.T) {
	home := filepath.Join(t.TempDir(), "watchtower-cmd-tests-home-guard")
	mod := filepath.Join(home, "go", "pkg", "mod", "example.com", "lib@v1.0.0")
	if err := os.MkdirAll(mod, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mod, "lib.go"), []byte("package lib\n"), 0o444); err != nil {
		t.Fatal(err)
	}
	// The go tool's module cache: every directory read-only.
	for dir := mod; dir != home; dir = filepath.Dir(dir) {
		if err := os.Chmod(dir, 0o555); err != nil {
			t.Fatal(err)
		}
	}

	if err := removeTestHome(home); err != nil {
		t.Fatalf("removeTestHome: %v", err)
	}
	if _, err := os.Lstat(home); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("home still there: %v", err)
	}
}

func TestRemoveTestHome_MissingIsNoError(t *testing.T) {
	if err := removeTestHome(filepath.Join(t.TempDir(), "gone")); err != nil {
		t.Fatalf("removeTestHome: %v", err)
	}
}
