package fsutil

import (
	"os"
	"path/filepath"
	"testing"
)

// An existing directory an older install created 0755 is narrowed; a new
// one is created 0700.
func TestMakePrivateDir_CreatesAndNarrows(t *testing.T) {
	existing := filepath.Join(t.TempDir(), "ws")
	if err := os.Mkdir(existing, 0o755); err != nil {
		t.Fatal(err)
	}
	fresh := filepath.Join(t.TempDir(), "a", "b")
	for _, dir := range []string{existing, fresh} {
		if err := MakePrivateDir(dir); err != nil {
			t.Fatalf("MakePrivateDir(%s): %v", dir, err)
		}
		info, err := os.Stat(dir)
		if err != nil {
			t.Fatal(err)
		}
		if perm := info.Mode().Perm(); perm != 0o700 {
			t.Errorf("%s: mode %o, want 700", dir, perm)
		}
	}
}
