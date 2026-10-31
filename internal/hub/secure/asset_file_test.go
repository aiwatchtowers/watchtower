package secure

import (
	"bytes"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func sealedFixture(t *testing.T, plain []byte, chunk uint32) (string, AssetDescriptor) {
	t.Helper()
	key := make([]byte, 32)
	_, _ = rand.Read(key)
	sealed, d, err := EncryptAsset(plain, ID{1}, key, chunk)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "sealed")
	if err := os.WriteFile(p, sealed, 0o600); err != nil {
		t.Fatal(err)
	}
	return p, d
}

func TestDecryptAssetFileRoundTrip(t *testing.T) {
	plain := bytes.Repeat([]byte("audio"), 700)
	src, d := sealedFixture(t, plain, 1024)
	dst := filepath.Join(t.TempDir(), "out.m4a")
	if err := DecryptAssetFile(src, dst, d); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(dst)
	if !bytes.Equal(got, plain) {
		t.Fatal("plaintext differs")
	}
	if st, _ := os.Stat(dst); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
}

func TestDecryptAssetFileFailuresLeaveNothing(t *testing.T) {
	plain := bytes.Repeat([]byte("x"), 3000)
	src, d := sealedFixture(t, plain, 1024)
	raw, _ := os.ReadFile(src)
	cases := map[string]struct {
		mutate func() string
		want   error
	}{
		"tampered": {func() string {
			b := append([]byte(nil), raw...)
			b[10] ^= 1
			p := filepath.Join(t.TempDir(), "s")
			_ = os.WriteFile(p, b, 0o600)
			return p
		}, ErrAuthenticationFailed},
		"truncated": {func() string {
			p := filepath.Join(t.TempDir(), "s")
			_ = os.WriteFile(p, raw[:len(raw)-1], 0o600)
			return p
		}, ErrAssetTruncated},
		"oversized": {func() string {
			p := filepath.Join(t.TempDir(), "s")
			_ = os.WriteFile(p, append(append([]byte(nil), raw...), 0), 0o600)
			return p
		}, ErrOversized},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			err := DecryptAssetFile(c.mutate(), filepath.Join(dir, "out"), d)
			if !errors.Is(err, c.want) {
				t.Fatalf("err = %v, want %v", err, c.want)
			}
			if ents, _ := os.ReadDir(dir); len(ents) != 0 {
				t.Fatalf("left %d files", len(ents))
			}
		})
	}
	t.Run("digest", func(t *testing.T) {
		bad := d
		bad.PlaintextDigest[0] ^= 1
		dir := t.TempDir()
		if err := DecryptAssetFile(src, filepath.Join(dir, "out"), bad); !errors.Is(err, ErrAssetDigestMismatch) {
			t.Fatalf("err = %v", err)
		}
		if ents, _ := os.ReadDir(dir); len(ents) != 0 {
			t.Fatal("left files")
		}
	})
}
