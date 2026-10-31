package secure

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/chacha20poly1305"
)

// The Kit's frozen vectors (WatchtowerKit/Tests/Fixtures/e2e, `make e2e-vectors`).
// Every deterministic byte is reproduced; the randomized ones (CryptoKit Ed25519
// signatures) are verified. These checks replace internal/mobilee2e.

// run is the fixtures' "a...b" byte run: a, a+1, ..., b.
func run(from, through int) []byte {
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
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "WatchtowerKit", "Tests", "Fixtures", "e2e", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatal(err)
	}
}

func cat(parts ...[]byte) []byte { return bytes.Join(parts, nil) }

func be16(v int) []byte { return binary.BigEndian.AppendUint16(nil, uint16(v)) }

// The fixtures' synthetic inputs (WatchtowerKit E2EFixtureKeys).
var (
	fixtureHubID = mustID("00112233-4455-6677-8899-AABBCCDDEEFF")
	linkNonce    = run(0xA0, 0xBF)
	metaKey      = run(0xC0, 0xDF)
	// SAS v2: the hub's confirm nonce, drawn after it accepted the hello.
	confirmNonce = run(0xE0, 0xFF)
	dataKey      = run(0x10, 0x2F)
	alertKey     = run(0xD0, 0xEF)
	fixtureNonce = run(0x50, 0x5B)
)

func mustID(s string) ID {
	id, err := ParseID(s)
	if err != nil {
		panic(err)
	}
	return id
}

type keys struct {
	hubKX, devKX   *ecdh.PrivateKey
	hubSig, devSig ed25519.PrivateKey
	deviceID       ID
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
		hubKX:  x(run(0x01, 0x20)),
		devKX:  x(run(0x21, 0x40)),
		hubSig: ed25519.NewKeyFromSeed(run(0x41, 0x60)),
		devSig: ed25519.NewKeyFromSeed(run(0x61, 0x80)),
	}
	k.deviceID = DeviceID(k.devSig.Public().(ed25519.PublicKey))
	return k
}

func relayKey(t *testing.T, k keys, dir Direction, epoch uint32) []byte {
	t.Helper()
	key, err := RelayKey(k.hubKX, k.devKX.PublicKey(), linkNonce, fixtureHubID, k.deviceID, epoch, dir)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func TestKitVectors_KDF(t *testing.T) {
	var fx struct {
		DeviceID    string            `json:"deviceID"`
		LinkCodeTag string            `json:"linkCodeTag"`
		RelayKeys   map[string]string `json:"relayKeys"`
		RecordNames map[string]string `json:"recordNames"`
		SAS         string            `json:"sas"`
	}
	loadFixture(t, "kdf.json", &fx)
	k := fixtureKeys(t)

	if got := k.deviceID.String(); got != fx.DeviceID || got != "880B6D06-8852-6316-76C4-9A1A29E1EB29" {
		t.Errorf("deviceID: got %s, fixture %s", got, fx.DeviceID)
	}
	if len(fx.RelayKeys) != 4 {
		t.Fatalf("fixture holds %d relay keys, want 4", len(fx.RelayKeys))
	}
	for _, epoch := range []uint32{1, 2} {
		for _, dir := range []Direction{PhoneToHub, HubToPhone} {
			name := fmt.Sprintf("%s/%d", dir, epoch)
			if got := hex.EncodeToString(relayKey(t, k, dir, epoch)); got != fx.RelayKeys[name] {
				t.Errorf("relay key %s: got %s, fixture %s", name, got, fx.RelayKeys[name])
			}
		}
	}
	const actionID = "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
	names := map[string]string{
		"data/owner_ask/42":        RecordName(metaKey, ZoneData, "owner_ask", "42"),
		"data/workbench/7":         RecordName(metaKey, ZoneData, "workbench", "7"),
		"relay/action/" + actionID: RecordName(metaKey, ZoneRelay, "action", actionID),
	}
	if len(fx.RecordNames) != len(names) {
		t.Fatalf("fixture holds %d record names, want %d", len(fx.RecordNames), len(names))
	}
	for key, got := range names {
		if got != fx.RecordNames[key] || len(got) != 26 {
			t.Errorf("record name %s: got %s, fixture %s", key, got, fx.RecordNames[key])
		}
	}
	sas := SAS(fixtureHubID, linkNonce, k.hubSig.Public().(ed25519.PublicKey), k.hubKX.PublicKey(),
		k.devSig.Public().(ed25519.PublicKey), k.devKX.PublicKey(), confirmNonce)
	if sas != fx.SAS || sas != "3378" {
		t.Errorf("sas: got %s, fixture %s", sas, fx.SAS)
	}
	if got := LinkCodeTag(linkNonce); got != fx.LinkCodeTag || fx.LinkCodeTag == "" {
		t.Errorf("linkCodeTag: got %s, fixture %s", got, fx.LinkCodeTag)
	}
	if len(confirmNonce) != ConfirmNonceLength {
		t.Errorf("confirm nonce %d bytes, want %d", len(confirmNonce), ConfirmNonceLength)
	}
}

func TestKitVectors_Padding(t *testing.T) {
	var fx struct {
		Cases []struct {
			Cap    int  `json:"cap"`
			Length int  `json:"length"`
			Padded *int `json:"padded"`
		} `json:"cases"`
	}
	loadFixture(t, "padding.json", &fx)
	if len(fx.Cases) == 0 {
		t.Fatal("no padding cases")
	}
	caps := map[int]bool{}
	for _, c := range fx.Cases {
		caps[c.Cap] = true
		got, ok := PaddedLength(c.Length, c.Cap)
		switch {
		case c.Padded == nil && ok:
			t.Errorf("length %d cap %d: got %d, fixture says it does not fit", c.Length, c.Cap, got)
		case c.Padded != nil && (!ok || got != *c.Padded):
			t.Errorf("length %d cap %d: got %d/%v, fixture %d", c.Length, c.Cap, got, ok, *c.Padded)
		}
	}
	// The fixture's caps are the two frame caps.
	if !caps[FrameCap(true)] || !caps[FrameCap(false)] || len(caps) != 2 {
		t.Errorf("fixture caps %v, frame caps %d/%d", caps, FrameCap(true), FrameCap(false))
	}
}

// assetChunkSize is the asset fixture's chunk size.
const assetChunkSize = 16

var assetFixtureID = mustID("0F0E0D0C-0B0A-0908-0706-050403020100")

// derivedDescriptor is key ‖ the 37-byte "WTA" header ‖ SHA-256(plain), built by hand.
func derivedDescriptor(key []byte, id ID, chunkSize uint32, plain []byte) ([]byte, uint32) {
	total := uint64(len(plain))
	count := uint32(max(1, (total+uint64(chunkSize)-1)/uint64(chunkSize)))
	header := cat([]byte("WTA"), []byte{1, 1}, id[:],
		binary.BigEndian.AppendUint32(nil, chunkSize), binary.BigEndian.AppendUint64(nil, total),
		binary.BigEndian.AppendUint32(nil, count))
	digest := sha256.Sum256(plain)
	return cat(key, header, digest[:]), count
}

func TestKitVectors_Asset(t *testing.T) {
	var fx struct {
		Sealed      map[string]string `json:"sealed"`
		Descriptors map[string]string `json:"descriptors"`
	}
	loadFixture(t, "asset.json", &fx)
	key := run(0xE0, 0xFF)
	if len(fx.Sealed) != 3 || len(fx.Descriptors) != 3 {
		t.Fatalf("fixture holds %d/%d assets, want 3", len(fx.Sealed), len(fx.Descriptors))
	}
	for _, length := range []int{0, 16, 40} {
		name := fmt.Sprint(length)
		t.Run(name, func(t *testing.T) {
			plain := make([]byte, length)
			for i := range plain {
				plain[i] = byte(i*7 + 3)
			}
			wantDesc, count := derivedDescriptor(key, assetFixtureID, assetChunkSize, plain)
			fixtureDesc := mustHex(t, fx.Descriptors[name])
			fixtureSealed := mustHex(t, fx.Sealed[name])
			if !bytes.Equal(wantDesc, fixtureDesc) {
				t.Errorf("hand-built descriptor %x, fixture %x", wantDesc, fixtureDesc)
			}

			sealed, desc, err := EncryptAsset(plain, assetFixtureID, key, assetChunkSize)
			if err != nil {
				t.Fatal(err)
			}
			if got := desc.Encode(); !bytes.Equal(got, fixtureDesc) || len(got) != AssetDescriptorLen {
				t.Errorf("descriptor %x, fixture %x", got, fixtureDesc)
			}
			if !bytes.Equal(sealed, fixtureSealed) {
				t.Errorf("sealed %x, fixture %x", sealed, fixtureSealed)
			}

			parsed, err := ParseAssetDescriptor(fixtureDesc)
			if err != nil {
				t.Fatal(err)
			}
			if parsed != desc {
				t.Errorf("parsed descriptor %+v, sealed %+v", parsed, desc)
			}
			if parsed.Header.TotalLength != uint64(length) || parsed.Header.ChunkCount != count {
				t.Errorf("descriptor header: total %d count %d", parsed.Header.TotalLength, parsed.Header.ChunkCount)
			}
			if want := int(count) * (assetChunkSize + 16); len(fixtureSealed) != want {
				t.Fatalf("sealed: %d bytes, want %d", len(fixtureSealed), want)
			}
			out, err := DecryptAsset(fixtureSealed, parsed)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(out, plain) {
				t.Errorf("plaintext %x, want %x", out, plain)
			}
			if got := sha256.Sum256(out); got != parsed.PlaintextDigest {
				t.Error("digest mismatch")
			}

			flipped := bytes.Clone(fixtureSealed)
			flipped[len(flipped)-1] ^= 1
			if _, err := DecryptAsset(flipped, parsed); !errors.Is(err, ErrAuthenticationFailed) {
				t.Errorf("flipped bit: %v, want ErrAuthenticationFailed", err)
			}
			// A chunk moved to another position must fail (the index is in the nonce and the AAD).
			if count > 1 {
				size := assetChunkSize + 16
				moved := cat(fixtureSealed[size:2*size], fixtureSealed[:size], fixtureSealed[2*size:])
				if _, err := DecryptAsset(moved, parsed); !errors.Is(err, ErrAuthenticationFailed) {
					t.Errorf("swapped chunks: %v, want ErrAuthenticationFailed", err)
				}
			}
			if _, err := DecryptAsset(fixtureSealed[:len(fixtureSealed)-1], parsed); !errors.Is(err, ErrAssetTruncated) {
				t.Errorf("short file: %v, want ErrAssetTruncated", err)
			}
			if _, err := DecryptAsset(append(bytes.Clone(fixtureSealed), 0), parsed); !errors.Is(err, ErrOversized) {
				t.Errorf("long file: %v, want ErrOversized", err)
			}
		})
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

// envWant is a case's spec-pinned expectations, independent of the
// fixture's own fields (class codes: Envelope.swift).
type envWant struct {
	class                  EnvelopeClass
	signed                 bool
	zone, kind, id, notify string
	payload                string
	asset                  bool
}

func envWants() map[string]envWant {
	return map[string]envWant{
		"data": {ClassData, true, "DataZone", "meeting_transcript", "9", "urgent", `{"title":"Acme sync"}`, true},
		"alert": {ClassAlert, true, "DataZone", "ask_alert", "42", "", `{"ask_id":42,"body":"Review the plan","event":"ask",` +
			`"key":"ask-42","quick":true,"title":"Acme","workbench_id":7,"workbench_name":"Acme"}`, false},
		"relayToHub":   {ClassRelayToHub, false, "RelayZone", "action", "a1", "", `{"op":"close"}`, false},
		"relayToPhone": {ClassRelayToPhone, false, "RelayZone", "echo", "a1", "", `{"ok":true}`, false},
	}
}

// fixtureAsset is the data case's descriptor: key 0x90..0xAF, asset id = hub id, chunk 16, plaintext "[]".
func fixtureAsset(t *testing.T) *AssetDescriptor {
	t.Helper()
	_, d, err := EncryptAsset([]byte("[]"), fixtureHubID, run(0x90, 0xAF), 16)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := derivedDescriptor(run(0x90, 0xAF), fixtureHubID, 16, []byte("[]"))
	if !bytes.Equal(d.Encode(), want) {
		t.Fatalf("asset descriptor %x, derived %x", d.Encode(), want)
	}
	return &d
}

func TestKitVectors_Envelope(t *testing.T) {
	var fx struct {
		Cases map[string]envCase `json:"cases"`
	}
	loadFixture(t, "envelope.json", &fx)
	k := fixtureKeys(t)
	hubSigPub := k.hubSig.Public().(ed25519.PublicKey)
	aeadKeys := map[string][]byte{
		"data":         dataKey,
		"alert":        alertKey,
		"relayToHub":   relayKey(t, k, PhoneToHub, 1),
		"relayToPhone": relayKey(t, k, HubToPhone, 1),
	}
	senders := map[string]ID{"data": fixtureHubID, "alert": fixtureHubID, "relayToHub": k.deviceID, "relayToPhone": fixtureHubID}
	zones := map[string]Zone{"DataZone": ZoneData, "RelayZone": ZoneRelay}
	wants := envWants()
	if len(fx.Cases) != len(wants) {
		t.Fatalf("fixture holds %d cases, want %d", len(fx.Cases), len(wants))
	}

	for name, c := range fx.Cases {
		t.Run(name, func(t *testing.T) {
			header := mustHex(t, c.Header)
			body := mustHex(t, c.Body)
			w, ok := wants[name]
			if !ok {
				t.Fatalf("unexpected case %q", name)
			}
			zone, ok := zones[c.Zone]
			if !ok || c.Zone != w.zone {
				t.Fatalf("zone %q, want %q", c.Zone, w.zone)
			}
			if c.Kind != w.kind || c.ID != w.id || c.NotifyLevel != w.notify || c.Payload != hex.EncodeToString([]byte(w.payload)) ||
				EnvelopeClass(c.EnvelopeClass) != w.class {
				t.Error("fixture metadata disagrees with the pinned expectations")
			}
			checkEnvelopeHeader(t, header, body, w, senders[name])
			signed := header[5]&1 != 0
			ctx := Context{Zone: zone, WireName: c.WireName}
			aad := cat(header, []byte{byte(zone)}, be16(len(c.WireName)), []byte(c.WireName))
			checkEnvelopeSignature(t, hubSigPub, signed, c.Signature, aad, body)

			// Reproduce header and body byte for byte with the fixture nonce.
			frame := InnerFrame{Kind: w.kind, ID: w.id, NotifyLevel: w.notify, Payload: []byte(w.payload)}
			if w.asset {
				frame.Asset = fixtureAsset(t)
			}
			var signer ed25519.PrivateKey
			if w.signed {
				signer = k.hubSig
			}
			sealed, err := SealSymmetric(frame, w.class, aeadKeys[name], fixtureHubID, senders[name], 1, 7, ctx, signer, fixtureNonce)
			if err != nil {
				t.Fatal(err)
			}
			if got := sealed[:HeaderLen]; !bytes.Equal(got, header) {
				t.Errorf("header %x, fixture %x", got, header)
			}
			if got := sealed[HeaderLen : HeaderLen+len(body)]; !bytes.Equal(got, body) {
				t.Errorf("body %x, fixture %x", got, body)
			}
			wantLen := HeaderLen + len(body)
			if w.signed {
				wantLen += 64
				// Our own (deterministic) signature verifies too.
				if !ed25519.Verify(hubSigPub, cat([]byte("wt/sig/v1"), aad, body), sealed[HeaderLen+len(body):]) {
					t.Error("own signature does not verify")
				}
			}
			if len(sealed) != wantLen {
				t.Errorf("sealed %d bytes, want %d", len(sealed), wantLen)
			}

			// Open the fixture's own wire bytes (its CryptoKit signature included).
			wire := cat(header, body, mustHex(t, c.Signature))
			var verifier ed25519.PublicKey
			if w.signed {
				verifier = hubSigPub
			}
			keyFor := func(Header) ([]byte, error) { return aeadKeys[name], nil }
			h, got, err := OpenSymmetric(wire, []EnvelopeClass{w.class}, ctx, verifier, keyFor)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			checkEnvelopeFrame(t, h, got, frame)

			// The wrong zone byte must not open (the AAD binds the zone).
			raw, err := chacha20poly1305.New(aeadKeys[name])
			if err != nil {
				t.Fatal(err)
			}
			bad := cat(header, []byte{3 - byte(zone)}, be16(len(c.WireName)), []byte(c.WireName))
			if _, err := raw.Open(nil, header[50:62], body, bad); err == nil {
				t.Error("opened under the wrong zone")
			}
			if name == "alert" {
				// The alert class is sealed with K_alert; the data key must not open it.
				dataKeyFor := func(Header) ([]byte, error) { return dataKey, nil }
				if _, _, err := OpenSymmetric(wire, []EnvelopeClass{ClassAlert}, ctx, hubSigPub, dataKeyFor); !errors.Is(err, ErrAuthenticationFailed) {
					t.Errorf("alert with the data key: %v, want ErrAuthenticationFailed", err)
				}
			}
		})
	}
}

// checkEnvelopeHeader checks the 68-byte "WTE" header's fields against the
// pinned expectations `w`, the case's `sender` and the fixture's nonce.
func checkEnvelopeHeader(t *testing.T, header, body []byte, w envWant, sender ID) {
	t.Helper()
	if len(header) != 68 || string(header[:3]) != "WTE" || header[3] != 1 || header[4] != 1 {
		t.Fatalf("bad header %x", header)
	}
	if signed := header[5]&1 != 0; signed != w.signed {
		t.Errorf("signed flag %v, want %v", signed, w.signed)
	}
	if hasAsset := header[5]&2 != 0; hasAsset != w.asset {
		t.Errorf("has-asset flag %v, want %v", hasAsset, w.asset)
	}
	if header[5]&4 == 0 {
		t.Error("padded flag not set")
	}
	if !bytes.Equal(header[6:22], fixtureHubID[:]) {
		t.Error("hub id")
	}
	if !bytes.Equal(header[22:38], sender[:]) {
		t.Errorf("sender id %x", header[22:38])
	}
	if binary.BigEndian.Uint32(header[38:42]) != 1 || binary.BigEndian.Uint64(header[42:50]) != 7 {
		t.Error("epoch/seq")
	}
	if !bytes.Equal(header[50:62], fixtureNonce) {
		t.Error("nonce")
	}
	if EnvelopeClass(binary.BigEndian.Uint16(header[62:64])) != w.class {
		t.Error("class")
	}
	if int(binary.BigEndian.Uint32(header[64:68])) != len(body) {
		t.Errorf("body_len %d, body %d", binary.BigEndian.Uint32(header[64:68]), len(body))
	}
}

// checkEnvelopeSignature checks the fixture's signature is present exactly
// when the header is `signed`, verifies over aad and body, and fails on a
// tampered body.
func checkEnvelopeSignature(t *testing.T, hubSigPub ed25519.PublicKey, signed bool, signature string, aad, body []byte) {
	t.Helper()
	if signed != (signature != "") {
		t.Fatalf("fixture signature presence %q disagrees with the signed flag", signature)
	}
	if !signed {
		return
	}
	sig := mustHex(t, signature)
	if !ed25519.Verify(hubSigPub, cat([]byte("wt/sig/v1"), aad, body), sig) {
		t.Error("stored signature does not verify")
	}
	tampered := cat([]byte("wt/sig/v1"), aad, body)
	tampered[len(tampered)-1] ^= 1
	if ed25519.Verify(hubSigPub, tampered, sig) {
		t.Error("signature verifies a tampered body")
	}
}

// checkEnvelopeFrame checks the opened header and frame against the frame that was sealed.
func checkEnvelopeFrame(t *testing.T, h Header, got, want InnerFrame) {
	t.Helper()
	// Padded to a bucket: 256 here.
	if h.BodyLen-16 != 256 {
		t.Errorf("padded frame %d bytes, want 256", h.BodyLen-16)
	}
	if got.Kind != want.Kind || got.ID != want.ID || got.NotifyLevel != want.NotifyLevel {
		t.Errorf("frame %q/%q/%q, want %q/%q/%q", got.Kind, got.ID, got.NotifyLevel, want.Kind, want.ID, want.NotifyLevel)
	}
	if !bytes.Equal(got.Payload, want.Payload) {
		t.Errorf("payload %q, want %q", got.Payload, want.Payload)
	}
	if (h.Flags&FlagHasAsset != 0) != (got.Asset != nil) {
		t.Error("has-asset flag disagrees with the frame")
	}
	if (got.Asset == nil) != (want.Asset == nil) || (got.Asset != nil && *got.Asset != *want.Asset) {
		t.Errorf("asset descriptor %+v, want %+v", got.Asset, want.Asset)
	}
}

// sealedData seals the data case's frame afresh (signed by hub_sig).
func sealedData(t *testing.T, k keys, ctx Context) []byte {
	t.Helper()
	w := envWants()["data"]
	frame := InnerFrame{Kind: w.kind, ID: w.id, NotifyLevel: w.notify, Payload: []byte(w.payload)}
	raw, err := SealSymmetric(frame, ClassData, dataKey, fixtureHubID, fixtureHubID, 1, 7, ctx, k.hubSig, nil)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestEnvelope_StrictParse(t *testing.T) {
	k := fixtureKeys(t)
	pub := k.hubSig.Public().(ed25519.PublicKey)
	ctx := Context{Zone: ZoneData, WireName: "abcdefghijklmnopqrstuvwxyz"}
	keyFor := func(Header) ([]byte, error) { return dataKey, nil }
	accept := []EnvelopeClass{ClassData}
	open := func(raw []byte, c Context, v ed25519.PublicKey) error {
		_, _, err := OpenSymmetric(raw, accept, c, v, keyFor)
		return err
	}
	good := sealedData(t, k, ctx)
	if err := open(good, ctx, pub); err != nil {
		t.Fatalf("fresh envelope does not open: %v", err)
	}

	mutate := func(f func([]byte)) []byte {
		b := bytes.Clone(good)
		f(b)
		return b
	}
	cases := []struct {
		name string
		raw  []byte
		ctx  Context
		ver  ed25519.PublicKey
		want error
	}{
		{"unknown flag bit", mutate(func(b []byte) { b[5] |= 8 }), ctx, pub, ErrFrameMalformed},
		{"version 2", mutate(func(b []byte) { b[3] = 2 }), ctx, pub, ErrUnsupportedVersion},
		{"suite 2", mutate(func(b []byte) { b[4] = 2 }), ctx, pub, ErrUnsupportedSuite},
		{"bad magic", mutate(func(b []byte) { b[0] = 'X' }), ctx, pub, ErrBadMagic},
		{"unknown class", mutate(func(b []byte) { b[63] = 9 }), ctx, pub, ErrUnknownClass},
		{"too short", good[:HeaderLen-1], ctx, pub, ErrTooShort},
		{"length mismatch", good[:len(good)-1], ctx, pub, ErrLengthMismatch},
		{"oversized", make([]byte, MaxEnvelopeBytes+1), ctx, pub, ErrOversized},
		{"no verifier for data", good, ctx, nil, ErrSignatureRequired},
		{"wrong verifier", good, ctx, k.devSig.Public().(ed25519.PublicKey), ErrSignatureInvalid},
		{"unsigned flag", mutate(func(b []byte) { b[5] &^= 1 }), ctx, pub, ErrLengthMismatch},
	}
	for _, c := range cases {
		if err := open(c.raw, c.ctx, c.ver); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", c.name, err, c.want)
		}
	}

	// Moving the envelope to another wire name or zone: the AAD no longer matches.
	unsigned := func(c Context) []byte {
		raw, err := SealSymmetric(InnerFrame{Kind: "action", ID: "a1", Payload: []byte("{}")}, ClassRelayToHub,
			dataKey, fixtureHubID, k.deviceID, 1, 7, c, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	relayCtx := Context{Zone: ZoneRelay, WireName: "zyxwvutsrqponmlkjihgfedcba"}
	relay := unsigned(relayCtx)
	relayAccept := []EnvelopeClass{ClassRelayToHub}
	if _, _, err := OpenSymmetric(relay, relayAccept, relayCtx, nil, keyFor); err != nil {
		t.Fatalf("relay envelope does not open: %v", err)
	}
	for _, moved := range []Context{{Zone: ZoneRelay, WireName: "other"}, {Zone: ZoneData, WireName: relayCtx.WireName}} {
		if _, _, err := OpenSymmetric(relay, relayAccept, moved, nil, keyFor); !errors.Is(err, ErrAuthenticationFailed) {
			t.Errorf("moved to %+v: %v, want ErrAuthenticationFailed", moved, err)
		}
	}
	// A verifier given for an unsigned envelope finds no signature.
	if _, _, err := OpenSymmetric(relay, relayAccept, relayCtx, pub, keyFor); !errors.Is(err, ErrSignatureMissing) {
		t.Errorf("unsigned with verifier: %v, want ErrSignatureMissing", err)
	}
	// A signed envelope moved fails its signature first.
	if err := open(good, Context{Zone: ZoneData, WireName: "other"}, pub); !errors.Is(err, ErrSignatureInvalid) {
		t.Errorf("signed moved: %v, want ErrSignatureInvalid", err)
	}
	// Alerts need a verifier too; a class not accepted is refused.
	if _, _, err := OpenSymmetric(good, []EnvelopeClass{ClassAlert}, ctx, pub, keyFor); !errors.Is(err, ErrWrongClass) {
		t.Errorf("data accepted as alert: %v, want ErrWrongClass", err)
	}
	alert, err := SealSymmetric(InnerFrame{Kind: "ask_alert", ID: "1", Payload: []byte("{}")}, ClassAlert, alertKey,
		fixtureHubID, fixtureHubID, 1, 1, ctx, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := OpenSymmetric(alert, []EnvelopeClass{ClassAlert}, ctx, nil, keyFor); !errors.Is(err, ErrSignatureRequired) {
		t.Errorf("alert without verifier: %v, want ErrSignatureRequired", err)
	}
	// HPKE classes are not symmetric.
	if _, err := SealSymmetric(InnerFrame{Kind: "x"}, ClassKeybox, dataKey, fixtureHubID, fixtureHubID, 1, 1, ctx, nil, nil); !errors.Is(err, ErrWrongClass) {
		t.Errorf("seal keybox: %v, want ErrWrongClass", err)
	}
	// The key resolver's own error surfaces as itself.
	sentinel := errors.New("epoch unknown")
	if _, _, err := OpenSymmetric(good, accept, ctx, pub, func(Header) ([]byte, error) { return nil, sentinel }); !errors.Is(err, sentinel) {
		t.Errorf("resolver error: %v, want it surfaced", err)
	}
	// A frame too large for the cap does not seal.
	huge := InnerFrame{Kind: "x", Payload: make([]byte, FrameCap(true))}
	if _, err := SealSymmetric(huge, ClassData, dataKey, fixtureHubID, fixtureHubID, 1, 1, ctx, k.hubSig, nil); !errors.Is(err, ErrOversized) {
		t.Errorf("huge frame: %v, want ErrOversized", err)
	}
}

func TestID_ParseAndString(t *testing.T) {
	id, err := ParseID("00112233-4455-6677-8899-aabbccddeeff")
	if err != nil {
		t.Fatal(err)
	}
	if id != fixtureHubID || id.String() != "00112233-4455-6677-8899-AABBCCDDEEFF" {
		t.Errorf("id %s", id)
	}
	for _, bad := range []string{"", "00112233445566778899AABBCCDDEEFF", "00112233-4455-6677-8899-AABBCCDDEEF", "0011223g-4455-6677-8899-AABBCCDDEEFF", "00112233_4455-6677-8899-AABBCCDDEEFF"} {
		if _, err := ParseID(bad); err == nil {
			t.Errorf("ParseID(%q) accepted", bad)
		}
	}
}
