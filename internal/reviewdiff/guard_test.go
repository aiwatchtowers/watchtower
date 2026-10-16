package reviewdiff

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// TestReview05_SnapshotAndDiffRunNothingFromTheFolder: a filter driver and an
// fsmonitor the folder's own config names never run.
func TestReview05_SnapshotAndDiffRunNothingFromTheFolder(t *testing.T) {
	dir := newRepo(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "evil.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ntouch "+marker+"\ncat\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "config", "filter.evil.clean", script)
	gitIn(t, dir, "config", "filter.evil.smudge", script)
	gitIn(t, dir, "config", "core.fsmonitor", script)
	writeFile(t, dir, ".gitattributes", "*.go filter=evil\n")
	writeFile(t, dir, "a.go", "package a // edited\n")

	r := openRepo(t, dir)
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Diff(context.Background(), EmptyTree, tree); err != nil {
		t.Fatal(err)
	}
	if _, err := r.File(context.Background(), tree, "a.go"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a command from the folder's git config ran")
	}
}
