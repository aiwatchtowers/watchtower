package automations

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// The window between a caller's content-hash check (`save
// --expect-content-hash`, save_automation's Execute) and the write is not
// atomic — an accepted limit. What bounds it: a symlink swapped in at the
// target inside that window is replaced as a directory entry by the atomic
// rename, never written through, so the write cannot land outside the
// recipe folder.
func TestWriteRecipe_ReplacesASymlinkNeverWritesThroughIt(t *testing.T) {
	f := newIndexerFixture(t)
	if err := os.MkdirAll(f.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside.md")
	if err := os.WriteFile(outside, []byte("not a recipe\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(f.dir, "mail.md")
	if err := os.Symlink(outside, path); err != nil {
		t.Fatal(err)
	}
	text := recipeText("A recipe.", "return 1")
	a, err := f.ix.WriteRecipe(context.Background(), Scope{Kind: ScopePersonal}, f.dir, path, []byte(text))
	if err != nil {
		t.Fatalf("WriteRecipe: %v", err)
	}
	if a.Path != path {
		t.Errorf("indexed path = %q; want %q", a.Path, path)
	}
	if got, _ := os.ReadFile(outside); string(got) != "not a recipe\n" {
		t.Errorf("the symlink's target was written: %q", got)
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("target after the write: %v, %v; want a regular file", info, err)
	}
}
