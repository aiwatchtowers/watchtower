package secure

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestInnerFrame_RoundTripAndPadding(t *testing.T) {
	asset := fixtureAsset(t)
	f := InnerFrame{Kind: "meeting_transcript", ID: "9", NotifyLevel: "urgent", Asset: asset, Payload: []byte(`{"a":1}`)}
	b, err := f.Encode(256)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) != 256 {
		t.Fatalf("encoded %d bytes, want 256", len(b))
	}
	want := 1 + 1 + 18 + 2 + 1 + 1 + 6 + 1 + AssetDescriptorLen + 4 + 7
	if f.EncodedLength() != want {
		t.Errorf("EncodedLength %d, want %d", f.EncodedLength(), want)
	}
	got, err := ParseInnerFrame(b)
	if err != nil {
		t.Fatal(err)
	}
	if got.Kind != f.Kind || got.ID != f.ID || got.NotifyLevel != f.NotifyLevel || !bytes.Equal(got.Payload, f.Payload) || *got.Asset != *asset {
		t.Errorf("round trip %+v", got)
	}
	if _, err := f.Encode(f.EncodedLength() - 1); !errors.Is(err, ErrOversized) {
		t.Errorf("short pad: %v, want ErrOversized", err)
	}
	long := InnerFrame{Kind: string(make([]byte, 256))}
	if _, err := long.Encode(1024); !errors.Is(err, ErrFrameMalformed) {
		t.Errorf("256-byte kind: %v, want ErrFrameMalformed", err)
	}
}

func TestInnerFrame_TrailingNonZeroIsMalformed(t *testing.T) {
	b, err := InnerFrame{Kind: "echo", ID: "a1", Payload: []byte(`{}`)}.Encode(64)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseInnerFrame(b); err != nil {
		t.Fatalf("zero padding refused: %v", err)
	}
	b[len(b)-1] = 1
	if _, err := ParseInnerFrame(b); !errors.Is(err, ErrFrameMalformed) {
		t.Errorf("non-zero padding: %v, want ErrFrameMalformed", err)
	}
	for name, bad := range map[string][]byte{
		"empty":         nil,
		"version 2":     {2, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		"asset flag 2":  {1, 0, 0, 0, 0, 2, 0, 0, 0, 0},
		"payload short": {1, 0, 0, 0, 0, 0, 0, 0, 0, 5},
		"bad utf8 kind": {1, 1, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0},
	} {
		if _, err := ParseInnerFrame(bad); !errors.Is(err, ErrFrameMalformed) {
			t.Errorf("%s: %v, want ErrFrameMalformed", name, err)
		}
	}
}

func TestEncryptAssetFile_StreamsAndRoundTrips(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "plain.bin")
	plain := make([]byte, 2*ChunkSize+123)
	for i := range plain {
		plain[i] = byte(i * 31)
	}
	if err := os.WriteFile(src, plain, 0o600); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dir, "sealed.bin")
	d, err := EncryptAssetFile(src, dst, assetFixtureID)
	if err != nil {
		t.Fatal(err)
	}
	if d.Header.ChunkCount != 3 || d.Header.ChunkSize != ChunkSize || d.Header.TotalLength != uint64(len(plain)) {
		t.Errorf("header %+v", d.Header)
	}
	info, err := os.Stat(dst)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("sealed file mode %v, want 0600", info.Mode().Perm())
	}
	sealed, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	out, err := DecryptAsset(sealed, d)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out, plain) {
		t.Error("round trip mismatch")
	}
	// Fresh key per asset.
	d2, err := EncryptAssetFile(src, dst, assetFixtureID)
	if err != nil {
		t.Fatal(err)
	}
	if d2.Key == d.Key {
		t.Error("key reused across assets")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Errorf("temp files left: %d entries", len(entries))
	}
	if _, err := EncryptAssetFile(filepath.Join(dir, "missing"), filepath.Join(dir, "x"), assetFixtureID); err == nil {
		t.Error("missing source sealed")
	}
}
