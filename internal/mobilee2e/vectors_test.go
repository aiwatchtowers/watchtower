package mobilee2e

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/chacha20poly1305"
)

// seq is the fixtures' "a...b" byte run: a, a+1, ..., b.
func seq(from, through int) []byte {
	out := make([]byte, 0, through-from+1)
	for i := from; i <= through; i++ {
		out = append(out, byte(i))
	}
	return out
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

func loadFixture(t *testing.T, name string, into any) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "WatchtowerKit", "Tests", "Fixtures", "e2e", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatal(err)
	}
}

func be16(v int) []byte    { return binary.BigEndian.AppendUint16(nil, uint16(v)) }
func be32(v uint32) []byte { return binary.BigEndian.AppendUint32(nil, v) }
func be64(v uint64) []byte { return binary.BigEndian.AppendUint64(nil, v) }

func cat(parts ...[]byte) []byte { return bytes.Join(parts, nil) }

// The fixtures' synthetic inputs (WatchtowerKit E2EFixtureKeys).
const hubIDText = "00112233-4455-6677-8899-AABBCCDDEEFF"

var (
	hubID     = mustParseUUID(hubIDText)
	linkNonce = seq(0xA0, 0xBF)
	metaKey   = seq(0xC0, 0xDF)
)

func mustParseUUID(s string) []byte {
	b, err := hex.DecodeString(strings.ReplaceAll(s, "-", ""))
	if err != nil || len(b) != 16 {
		panic("bad uuid " + s)
	}
	return b
}

func formatUUID(b []byte) string {
	h := strings.ToUpper(hex.EncodeToString(b))
	return fmt.Sprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
}

type keys struct {
	hubKX, devKX *ecdh.PrivateKey
	hubSig       ed25519.PrivateKey
	devSig       ed25519.PrivateKey
	deviceID     []byte
}

func fixtureKeys(t *testing.T) keys {
	t.Helper()
	x := func(seed []byte) *ecdh.PrivateKey {
		k, err := ecdh.X25519().NewPrivateKey(seed)
		if err != nil {
			t.Fatal(err)
		}
		return k
	}
	k := keys{
		hubKX:  x(seq(0x01, 0x20)),
		devKX:  x(seq(0x21, 0x40)),
		hubSig: ed25519.NewKeyFromSeed(seq(0x41, 0x60)),
		devSig: ed25519.NewKeyFromSeed(seq(0x61, 0x80)),
	}
	// D7: UUID of SHA-256("wt/device-id/v1" || dev_sig_pub)[0..<16].
	sum := sha256.Sum256(cat([]byte("wt/device-id/v1"), k.devSig.Public().(ed25519.PublicKey)))
	k.deviceID = sum[:16]
	return k
}

func relayKey(t *testing.T, k keys, dir string, epoch uint32) []byte {
	t.Helper()
	shared, err := k.hubKX.ECDH(k.devKX.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	info := cat([]byte("wt/relay/v1/"+dir), []byte{0}, hubID, k.deviceID, be32(epoch))
	out, err := hkdf.Key(sha256.New, shared, linkNonce, string(info), 32)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func recordName(zone byte, kind, id string) string {
	msg := cat([]byte("wt/name/v1"), []byte{zone, byte(len(kind))}, []byte(kind), []byte(id))
	mac := hmac.New(sha256.New, metaKey)
	mac.Write(msg)
	enc := base32.StdEncoding.WithPadding(base32.NoPadding)
	return strings.ToLower(enc.EncodeToString(mac.Sum(nil)[:16]))
}

func sas(t *testing.T, k keys) string {
	t.Helper()
	transcript := cat([]byte("wt/sas/v1"), hubID, linkNonce,
		k.hubSig.Public().(ed25519.PublicKey), k.hubKX.PublicKey().Bytes(),
		k.devSig.Public().(ed25519.PublicKey), k.devKX.PublicKey().Bytes())
	digest := sha256.Sum256(transcript)
	okm, err := hkdf.Key(sha256.New, digest[:], linkNonce, "wt/sas/v1", 4)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%04d", binary.BigEndian.Uint32(okm)%10000)
}

func TestKDFVectorsMatchAGoDerivation(t *testing.T) {
	var fx struct {
		DeviceID    string            `json:"deviceID"`
		RelayKeys   map[string]string `json:"relayKeys"`
		RecordNames map[string]string `json:"recordNames"`
		SAS         string            `json:"sas"`
	}
	loadFixture(t, "kdf.json", &fx)
	k := fixtureKeys(t)

	if got := formatUUID(k.deviceID); got != fx.DeviceID {
		t.Errorf("deviceID: got %s, fixture %s", got, fx.DeviceID)
	}
	if len(fx.RelayKeys) != 4 {
		t.Fatalf("fixture holds %d relay keys, want 4", len(fx.RelayKeys))
	}
	for _, epoch := range []uint32{1, 2} {
		for _, dir := range []string{"p2h", "h2p"} {
			name := fmt.Sprintf("%s/%d", dir, epoch)
			if got := hex.EncodeToString(relayKey(t, k, dir, epoch)); got != fx.RelayKeys[name] {
				t.Errorf("relay key %s: got %s, fixture %s", name, got, fx.RelayKeys[name])
			}
		}
	}
	const actionID = "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
	names := map[string]string{
		"data/owner_ask/42":        recordName(1, "owner_ask", "42"),
		"data/workbench/7":         recordName(1, "workbench", "7"),
		"relay/action/" + actionID: recordName(2, "action", actionID),
	}
	if len(fx.RecordNames) != len(names) {
		t.Fatalf("fixture holds %d record names, want %d", len(fx.RecordNames), len(names))
	}
	for key, got := range names {
		if got != fx.RecordNames[key] {
			t.Errorf("record name %s: got %s, fixture %s", key, got, fx.RecordNames[key])
		}
	}
	if got := sas(t, k); got != fx.SAS {
		t.Errorf("sas: got %s, fixture %s", got, fx.SAS)
	}
}

// assetHeader is the 37-byte "WTA" header.
func assetHeader(id []byte, chunkSize uint32, total uint64) ([]byte, uint32) {
	count := uint32(max(1, (total+uint64(chunkSize)-1)/uint64(chunkSize)))
	return cat([]byte("WTA"), []byte{1, 1}, id, be32(chunkSize), be64(total), be32(count)), count
}

func chunkNonce(c uint32) []byte { return cat(be32(0), be64(uint64(c))) }

func chunkAAD(header []byte, c, count uint32) []byte {
	last := byte(0)
	if c == count-1 {
		last = 1
	}
	return cat(header, be64(uint64(c)), []byte{last})
}

func TestAssetVectorsDecryptInGo(t *testing.T) {
	var fx struct {
		Sealed      map[string]string `json:"sealed"`
		Descriptors map[string]string `json:"descriptors"`
	}
	loadFixture(t, "asset.json", &fx)
	key := seq(0xE0, 0xFF)
	assetID := mustParseUUID("0F0E0D0C-0B0A-0908-0706-050403020100")
	const chunkSize = 16
	if len(fx.Sealed) != 3 {
		t.Fatalf("fixture holds %d assets, want 3", len(fx.Sealed))
	}
	for _, length := range []int{0, 16, 40} {
		name := fmt.Sprint(length)
		plain := make([]byte, length)
		for i := range plain {
			plain[i] = byte(i*7 + 3)
		}
		digest := sha256.Sum256(plain)
		header, count := assetHeader(assetID, chunkSize, uint64(length))
		wantDescriptor := cat(key, header, digest[:])
		if got := hex.EncodeToString(wantDescriptor); got != fx.Descriptors[name] {
			t.Errorf("descriptor %s: got %s, fixture %s", name, got, fx.Descriptors[name])
		}

		// Decrypt the frozen sealed file with the frozen descriptor's own header.
		desc := mustHex(t, fx.Descriptors[name])
		sealed := mustHex(t, fx.Sealed[name])
		if len(desc) != 101 {
			t.Fatalf("descriptor %s: %d bytes, want 101", name, len(desc))
		}
		dKey, dHeader, dDigest := desc[:32], desc[32:69], desc[69:]
		total := binary.BigEndian.Uint64(dHeader[25:33])
		dCount := binary.BigEndian.Uint32(dHeader[33:37])
		if total != uint64(length) || dCount != count {
			t.Errorf("descriptor %s header: total %d count %d", name, total, dCount)
		}
		if want := int(count) * (chunkSize + 16); len(sealed) != want {
			t.Fatalf("sealed %s: %d bytes, want %d", name, len(sealed), want)
		}
		aead, err := chacha20poly1305.New(dKey)
		if err != nil {
			t.Fatal(err)
		}
		var out []byte
		for c := uint32(0); c < dCount; c++ {
			chunk := sealed[int(c)*(chunkSize+16) : int(c+1)*(chunkSize+16)]
			p, err := aead.Open(nil, chunkNonce(c), chunk, chunkAAD(dHeader, c, dCount))
			if err != nil {
				t.Fatalf("asset %s chunk %d: %v", name, c, err)
			}
			out = append(out, p...)
		}
		if total > uint64(len(out)) {
			t.Fatalf("asset %s: total_len %d exceeds %d decrypted bytes", name, total, len(out))
		}
		out = out[:total]
		if !bytes.Equal(out, plain) {
			t.Errorf("asset %s: plaintext mismatch", name)
		}
		if got := sha256.Sum256(out); !bytes.Equal(got[:], dDigest) {
			t.Errorf("asset %s: digest mismatch", name)
		}
		// A chunk moved to another position must fail (index is in nonce and AAD).
		if dCount > 1 {
			if _, err := aead.Open(nil, chunkNonce(1), sealed[:chunkSize+16], chunkAAD(dHeader, 1, dCount)); err == nil {
				t.Errorf("asset %s: chunk 0 opened as chunk 1", name)
			}
		}
	}
}

type envCase struct {
	EnvelopeClass int    `json:"envelopeClass"`
	Zone          string `json:"zone"`
	WireName      string `json:"wireName"`
	Kind          string `json:"kind"`
	ID            string `json:"id"`
	NotifyLevel   string `json:"notifyLevel"`
	Payload       string `json:"payload"`
	Header        string `json:"header"`
	Body          string `json:"body"`
	Signature     string `json:"signature"`
}

type frame struct {
	kind, id, notify string
	asset            []byte
	payload          []byte
}

// parseFrame reads inner_ver | kind_len | kind | id_len u16 | id | notify_len | notify |
// asset_flag | [descriptor 101] | payload_len u32 | payload | zero padding.
func parseFrame(t *testing.T, b []byte) frame {
	t.Helper()
	pos := 0
	take := func(n int) []byte {
		if n < 0 || pos+n > len(b) {
			t.Fatalf("frame truncated at %d (+%d of %d)", pos, n, len(b))
		}
		defer func() { pos += n }()
		return b[pos : pos+n]
	}
	if v := take(1)[0]; v != 1 {
		t.Fatalf("inner version %d", v)
	}
	var f frame
	f.kind = string(take(int(take(1)[0])))
	f.id = string(take(int(binary.BigEndian.Uint16(take(2)))))
	f.notify = string(take(int(take(1)[0])))
	switch flag := take(1)[0]; flag {
	case 0:
	case 1:
		f.asset = take(101)
	default:
		t.Fatalf("asset flag %d", flag)
	}
	f.payload = take(int(binary.BigEndian.Uint32(take(4))))
	for _, z := range b[pos:] {
		if z != 0 {
			t.Fatal("non-zero padding")
		}
	}
	return f
}

func TestEnvelopeVectorsOpenInGo(t *testing.T) {
	var fx struct {
		Cases map[string]envCase `json:"cases"`
	}
	loadFixture(t, "envelope.json", &fx)
	k := fixtureKeys(t)
	hubSigPub := k.hubSig.Public().(ed25519.PublicKey)
	aeadKeys := map[string][]byte{
		"data":         seq(0x10, 0x2F),
		"relayToHub":   relayKey(t, k, "p2h", 1),
		"relayToPhone": relayKey(t, k, "h2p", 1),
	}
	senders := map[string][]byte{"data": hubID, "relayToHub": k.deviceID, "relayToPhone": hubID}
	zoneByte := map[string]byte{"DataZone": 1, "RelayZone": 2}
	// Spec-pinned expectations, independent of the fixture's own fields (class codes: Envelope.swift).
	type want struct {
		class                  int
		signed                 bool
		zone, kind, id, notify string
		payload                string
	}
	wants := map[string]want{
		"data":         {1, true, "DataZone", "meeting_transcript", "9", "urgent", `{"title":"Acme sync"}`},
		"relayToHub":   {5, false, "RelayZone", "action", "a1", "", `{"op":"close"}`},
		"relayToPhone": {6, false, "RelayZone", "echo", "a1", "", `{"ok":true}`},
	}
	nonce := seq(0x50, 0x5B)
	if len(fx.Cases) != 3 {
		t.Fatalf("fixture holds %d cases, want 3", len(fx.Cases))
	}

	for name, c := range fx.Cases {
		t.Run(name, func(t *testing.T) {
			header := mustHex(t, c.Header)
			body := mustHex(t, c.Body)
			if len(header) != 68 || string(header[:3]) != "WTE" || header[3] != 1 || header[4] != 1 {
				t.Fatalf("bad header %x", header)
			}
			w, ok := wants[name]
			if !ok {
				t.Fatalf("unexpected case %q", name)
			}
			zb, ok := zoneByte[c.Zone]
			if !ok || c.Zone != w.zone {
				t.Fatalf("zone %q, want %q", c.Zone, w.zone)
			}
			signed := header[5]&1 != 0
			if signed != w.signed {
				t.Errorf("signed flag %v, want %v", signed, w.signed)
			}
			hasAsset := header[5]&2 != 0
			if header[5]&4 == 0 {
				t.Error("padded flag not set")
			}
			if !bytes.Equal(header[6:22], hubID) {
				t.Error("hub id")
			}
			if !bytes.Equal(header[22:38], senders[name]) {
				t.Errorf("sender id %x", header[22:38])
			}
			if binary.BigEndian.Uint32(header[38:42]) != 1 || binary.BigEndian.Uint64(header[42:50]) != 7 {
				t.Error("epoch/seq")
			}
			if !bytes.Equal(header[50:62], nonce) {
				t.Error("nonce")
			}
			if int(binary.BigEndian.Uint16(header[62:64])) != w.class {
				t.Error("class")
			}
			if int(binary.BigEndian.Uint32(header[64:68])) != len(body) {
				t.Errorf("body_len %d, body %d", binary.BigEndian.Uint32(header[64:68]), len(body))
			}

			aad := cat(header, []byte{zb}, be16(len(c.WireName)), []byte(c.WireName))
			if signed != (c.Signature != "") {
				t.Fatalf("fixture signature presence %q disagrees with the signed flag", c.Signature)
			}
			if signed {
				sig := mustHex(t, c.Signature)
				if !ed25519.Verify(hubSigPub, cat([]byte("wt/sig/v1"), aad, body), sig) {
					t.Error("stored signature does not verify")
				}
				tampered := cat([]byte("wt/sig/v1"), aad, body)
				tampered[len(tampered)-1] ^= 1
				if ed25519.Verify(hubSigPub, tampered, sig) {
					t.Error("signature verifies a tampered body")
				}
			}

			aead, err := chacha20poly1305.New(aeadKeys[name])
			if err != nil {
				t.Fatal(err)
			}
			plain, err := aead.Open(nil, header[50:62], body, aad)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			// Padded to a bucket: 256 here.
			if len(plain) != 256 {
				t.Errorf("padded frame %d bytes, want 256", len(plain))
			}
			f := parseFrame(t, plain)
			if f.kind != w.kind || f.id != w.id || f.notify != w.notify {
				t.Errorf("frame %q/%q/%q, want %q/%q/%q", f.kind, f.id, f.notify, w.kind, w.id, w.notify)
			}
			if string(f.payload) != w.payload {
				t.Errorf("payload %q, want %q", f.payload, w.payload)
			}
			if c.Kind != w.kind || c.ID != w.id || c.NotifyLevel != w.notify || c.Payload != hex.EncodeToString([]byte(w.payload)) {
				t.Error("fixture metadata disagrees with the pinned expectations")
			}
			if hasAsset != (f.asset != nil) {
				t.Error("has-asset flag disagrees with the frame")
			}
			if f.asset != nil {
				// Key 0x90..0xAF, asset id = hub id, chunk 16, plaintext "[]".
				digest := sha256.Sum256([]byte("[]"))
				hdr, _ := assetHeader(hubID, 16, 2)
				want := cat(seq(0x90, 0xAF), hdr, digest[:])
				if !bytes.Equal(f.asset, want) {
					t.Errorf("asset descriptor %x, derived %x", f.asset, want)
				}
			}
			// The wrong zone byte must not open (AAD binds the zone).
			bad := cat(header, []byte{3 - zb}, be16(len(c.WireName)), []byte(c.WireName))
			if _, err := aead.Open(nil, header[50:62], body, bad); err == nil {
				t.Error("opened under the wrong zone")
			}
		})
	}
}
