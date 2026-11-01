package identity

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/hub/state"
)

func TestForDesktopHostRecordsTheChoiceOnce(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	first, err := ForDesktopHost(st, dir, false)
	if err != nil {
		t.Fatalf("first call: %v", err)
	}
	fs, ok := first.(FileStore)
	if !ok || fs.Path != filepath.Join(dir, FileName) {
		t.Fatalf("first call = %#v, want FileStore at <dir>/%s", first, FileName)
	}
	if v, ok, _ := st.Meta(MetaIdentityStore); !ok || v != IdentityStoreFile {
		t.Fatalf("hub_meta %s = %q (set %v), want %q", MetaIdentityStore, v, ok, IdentityStoreFile)
	}

	second, err := ForDesktopHost(st, dir, true)
	if err != nil {
		t.Fatalf("second call: %v", err)
	}
	if _, ok := second.(FileStore); !ok {
		t.Fatalf("second call with keychainWorks = %T, want the recorded FileStore", second)
	}
	if v, _, _ := st.Meta(MetaIdentityStore); v != IdentityStoreFile {
		t.Fatalf("hub_meta %s re-decided to %q", MetaIdentityStore, v)
	}
}

func TestForDesktopHostFollowsAKeychainRecord(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.SetMeta(MetaIdentityStore, IdentityStoreKeychain); err != nil {
		t.Fatal(err)
	}
	got, err := ForDesktopHost(st, dir, false)
	if !keychainAvailable {
		if !errors.Is(err, ErrNoKeychain) {
			t.Fatalf("keychain record off darwin = %v, want ErrNoKeychain", err)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	if ks, ok := got.(KeychainStore); !ok || ks.Service != KeychainService {
		t.Fatalf("got %#v, want KeychainStore{%q}", got, KeychainService)
	}
}

func TestForDesktopHostRefusesAnUnknownRecord(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.SetMeta(MetaIdentityStore, "vault"); err != nil {
		t.Fatal(err)
	}
	if _, err := ForDesktopHost(st, dir, true); err == nil {
		t.Fatal("an unknown recorded store was accepted")
	}
}

func TestKeychainUsableDefaultsToTrue(t *testing.T) {
	if KeychainBuildFlag != "" || !KeychainUsable {
		t.Fatalf("KeychainBuildFlag=%q KeychainUsable=%v; a plain build must default to the Keychain", KeychainBuildFlag, KeychainUsable)
	}
}

func TestFileStoreStagedIsPrivate(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	s := FileStore{Path: filepath.Join(dir, FileName)}
	if _, ok, err := s.Staged(); ok || err != nil {
		t.Fatalf("Staged before SaveStaged = %v, %v; want none", ok, err)
	}
	if err := s.PromoteStaged(); !errors.Is(err, ErrNoIdentity) {
		t.Fatalf("PromoteStaged with nothing staged = %v, want ErrNoIdentity", err)
	}
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SaveStaged(id); err != nil {
		t.Fatalf("SaveStaged: %v", err)
	}
	staged := filepath.Join(dir, StagedFileName)
	fi, err := os.Stat(staged)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("staged mode %o, want 600", fi.Mode().Perm())
	}
	got, ok, err := s.Staged()
	if err != nil || !ok || !got.Signing.Equal(id.Signing) {
		t.Fatalf("Staged = %v, %v; want the saved identity", ok, err)
	}
	if _, err := s.Load(); !errors.Is(err, ErrNoIdentity) {
		t.Fatalf("live Load before promote = %v, want ErrNoIdentity", err)
	}

	if err := os.Chmod(staged, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Staged(); !errors.Is(err, ErrInsecureMode) {
		t.Fatalf("Staged with 0640 = %v, want ErrInsecureMode", err)
	}
	if err := s.PromoteStaged(); !errors.Is(err, ErrInsecureMode) {
		t.Fatalf("PromoteStaged with 0640 = %v, want ErrInsecureMode", err)
	}
	if err := os.Chmod(staged, 0o600); err != nil {
		t.Fatal(err)
	}

	if err := s.PromoteStaged(); err != nil {
		t.Fatalf("PromoteStaged: %v", err)
	}
	live, err := s.Load()
	if err != nil || !live.Signing.Equal(id.Signing) || live.Wrap != id.Wrap ||
		!bytes.Equal(live.Agreement.Bytes(), id.Agreement.Bytes()) {
		t.Fatalf("live Load after promote = %v; want the staged identity", err)
	}
	if _, ok, _ := s.Staged(); ok {
		t.Fatal("the staged file is still there after promote")
	}

	if err := s.SaveStaged(id); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteStaged(); err != nil {
		t.Fatalf("DeleteStaged: %v", err)
	}
	if err := s.DeleteStaged(); err != nil {
		t.Fatalf("DeleteStaged twice: %v", err)
	}
	if _, err := os.Stat(staged); !os.IsNotExist(err) {
		t.Fatalf("staged file after DeleteStaged: %v", err)
	}
}

func TestKeychainErrorNamesOnlyTheStatus(t *testing.T) {
	err := &KeychainError{Op: "load", Status: -25293}
	if got, want := err.Error(), "identity: keychain load: OSStatus -25293 (errSecAuthFailed)"; got != want {
		t.Fatalf("Error() = %q, want %q", got, want)
	}
	if !strings.Contains((&KeychainError{Op: "save", Status: 1}).Error(), "(other)") {
		t.Fatal("an unknown status is not classed as other")
	}
}
