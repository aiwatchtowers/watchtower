package identity

import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestFileStore_RoundTrip(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	s := FileStore{Path: filepath.Join(dir, FileName)}
	if _, err := s.Load(); !errors.Is(err, ErrNoIdentity) {
		t.Fatalf("Load before Save = %v, want ErrNoIdentity", err)
	}
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Save(id); err != nil {
		t.Fatalf("Save: %v", err)
	}
	fi, err := os.Stat(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("file mode %o, want 600", fi.Mode().Perm())
	}
	di, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if di.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode %o, want 700", di.Mode().Perm())
	}
	got, err := s.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !got.Signing.Equal(id.Signing) || !got.RelayAuth.Equal(id.RelayAuth) || got.Wrap != id.Wrap ||
		!bytes.Equal(got.Agreement.Bytes(), id.Agreement.Bytes()) {
		t.Fatal("loaded identity differs from the saved one")
	}
	if got.Signing.Equal(got.RelayAuth) {
		t.Fatal("hub_sig and relay_auth are the same key")
	}
	matches, _ := filepath.Glob(filepath.Join(dir, ".identity-*"))
	if len(matches) != 0 {
		t.Fatalf("temp files left behind: %v", matches)
	}
}

func TestFileStore_RefusesLooserMode(t *testing.T) {
	s := FileStore{Path: filepath.Join(t.TempDir(), FileName)}
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Save(id); err != nil {
		t.Fatal(err)
	}
	for _, mode := range []os.FileMode{0o644, 0o640, 0o604, 0o660} {
		if err := os.Chmod(s.Path, mode); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Load(); !errors.Is(err, ErrInsecureMode) {
			t.Fatalf("mode %o: Load = %v, want ErrInsecureMode", mode, err)
		}
	}
	if err := os.Chmod(s.Path, 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); err != nil {
		t.Fatalf("mode 400: Load = %v", err)
	}
}

func TestFileStore_RefusesSymlinkAndMalformed(t *testing.T) {
	dir := t.TempDir()
	target := FileStore{Path: filepath.Join(dir, "real.key")}
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := target.Save(id); err != nil {
		t.Fatal(err)
	}
	link := FileStore{Path: filepath.Join(dir, FileName)}
	if err := os.Symlink(target.Path, link.Path); err != nil {
		t.Fatal(err)
	}
	if _, err := link.Load(); !errors.Is(err, ErrInsecureMode) {
		t.Fatalf("symlink: Load = %v, want ErrInsecureMode", err)
	}
	for _, body := range [][]byte{nil, []byte("short"), bytes.Repeat([]byte{1}, fileLen), append(append([]byte{}, fileMagic[:]...), make([]byte, 4*32+1)...)} {
		p := filepath.Join(dir, "bad.key")
		if err := os.WriteFile(p, body, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := (FileStore{Path: p}).Load(); !errors.Is(err, errMalformed) {
			t.Fatalf("body of %d bytes: Load = %v, want malformed", len(body), err)
		}
	}
}

func TestFileStore_RefusesIncompleteIdentity(t *testing.T) {
	s := FileStore{Path: filepath.Join(t.TempDir(), FileName)}
	if err := s.Save(Identity{}); err == nil {
		t.Fatal("Save of an empty identity succeeded")
	}
	if _, err := os.Stat(s.Path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a file was written: %v", err)
	}
}

func TestIdentity_ZeroClearsKeys(t *testing.T) {
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	sig, relay := id.Signing, id.RelayAuth
	id.Zero()
	if !bytes.Equal(sig, make([]byte, ed25519.PrivateKeySize)) || !bytes.Equal(relay, make([]byte, ed25519.PrivateKeySize)) {
		t.Fatal("Ed25519 key bytes survived Zero")
	}
	if id.Wrap != ([32]byte{}) || id.Agreement != nil || id.Signing != nil {
		t.Fatal("Zero left key material reachable")
	}
}

func TestRelayDeviceID_IsLowerBase32OfSHA256(t *testing.T) {
	pub := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x41}, 32)).Public().(ed25519.PublicKey)
	got := RelayDeviceID(pub)
	if len(got) != 52 {
		t.Fatalf("len %d, want 52 (256 bits unpadded base32)", len(got))
	}
	for _, c := range got {
		if !(c >= 'a' && c <= 'z' || c >= '2' && c <= '7') {
			t.Fatalf("%q is not lowercase base32", got)
		}
	}
	if RelayDeviceID(pub) != got {
		t.Fatal("not deterministic")
	}
}
