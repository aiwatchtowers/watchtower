package hub

import (
	"path/filepath"
	"testing"

	"watchtower/internal/config"
)

// The live hub dir sits beside the workspaces but can never be one.
func TestDefaultHubDirCannotBeAWorkspace(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	dir, err := DefaultDir()
	if err != nil {
		t.Fatal(err)
	}
	root, err := config.DataRoot()
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(root, ".hub"); dir != want {
		t.Fatalf("DefaultDir = %q, want %q", dir, want)
	}
	if config.ValidWorkspaceRe.MatchString(filepath.Base(dir)) {
		t.Fatalf("%q is a valid workspace name", filepath.Base(dir))
	}
}

func TestDefaultHubDirWithoutHomeIsAnError(t *testing.T) {
	t.Setenv("HOME", "")
	if dir, err := DefaultDir(); err == nil || dir != "" {
		t.Fatalf("DefaultDir without a home = %q, %v, want an error", dir, err)
	}
}
