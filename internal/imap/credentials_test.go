package imap

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// TestCredentialStore_RoundTripAndLifecycle: Save writes 0600 even over a
// pre-existing wider file, Load returns what was saved (an Outlook refresh
// token here), Exists tracks the file, and Delete is idempotent.
func TestCredentialStore_RoundTripAndLifecycle(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ws")
	st := NewCredentialStore(dir, 42)
	path := filepath.Join(dir, "imap_credentials_42.json")

	if st.Exists() {
		t.Fatal("Exists before Save = true")
	}
	if _, err := st.Load(); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("Load before Save: err = %v, want fs.ErrNotExist", err)
	}

	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"password":"old"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.Save(&Credentials{RefreshToken: "rt-new"}); err != nil {
		t.Fatalf("Save: %v", err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v, want 0600 over a pre-existing 0644 file", fi.Mode().Perm())
	}
	if !st.Exists() {
		t.Error("Exists after Save = false")
	}
	got, err := st.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.RefreshToken != "rt-new" || got.Password != "" {
		t.Errorf("Load = %+v, want only RefreshToken rt-new", got)
	}

	if err := st.Delete(); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if st.Exists() {
		t.Error("Exists after Delete = true")
	}
	if err := st.Delete(); err != nil {
		t.Errorf("second Delete: %v, want nil (missing file is not an error)", err)
	}
}

// TestCredentialStore_LoadCorruptFile: a torn or hand-edited file is a parse
// error, never an empty credential that would look like a valid login.
func TestCredentialStore_LoadCorruptFile(t *testing.T) {
	dir := t.TempDir()
	st := NewCredentialStore(dir, 1)
	if err := os.WriteFile(filepath.Join(dir, "imap_credentials_1.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	creds, err := st.Load()
	if err == nil {
		t.Fatalf("Load = %+v, nil; want a parse error", creds)
	}
}

// TestCredentialStore_DeleteSurfacesRealErrors: only a missing file is
// swallowed — a path Delete cannot remove (a non-empty directory) errors.
func TestCredentialStore_DeleteSurfacesRealErrors(t *testing.T) {
	dir := t.TempDir()
	st := NewCredentialStore(dir, 2)
	occupied := filepath.Join(dir, "imap_credentials_2.json")
	if err := os.MkdirAll(filepath.Join(occupied, "child"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := st.Delete(); err == nil {
		t.Error("Delete over a non-empty directory = nil, want an error")
	}
}
