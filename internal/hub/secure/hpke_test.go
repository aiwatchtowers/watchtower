package secure

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"testing"
)

// RFC 9180 A.2.1 (X25519 / HKDF-SHA256 / ChaCha20-Poly1305, mode base, seq 0)
// opened through the hello/keybox body path.
func TestHPKE_RFC9180A21(t *testing.T) {
	var fx struct {
		Info string `json:"info"`
		SkRm string `json:"skRm"`
		PkRm string `json:"pkRm"`
		Enc  string `json:"enc"`
		AAD  string `json:"aad"`
		PT   string `json:"pt"`
		CT   string `json:"ct"`
	}
	loadFixture(t, "hpke-rfc9180-a21.json", &fx)
	sk, err := ecdh.X25519().NewPrivateKey(mustHex(t, fx.SkRm))
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(sk.PublicKey().Bytes()); got != fx.PkRm {
		t.Fatalf("pkRm %s, RFC %s", got, fx.PkRm)
	}
	body := cat(mustHex(t, fx.Enc), mustHex(t, fx.CT))
	plain, err := openHPKEBody(sk, mustHex(t, fx.Info), mustHex(t, fx.AAD), body)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if !bytes.Equal(plain, mustHex(t, fx.PT)) {
		t.Errorf("pt %x, RFC %s", plain, fx.PT)
	}
	// A flipped bit, another aad, another info: one outcome.
	flipped := bytes.Clone(body)
	flipped[len(flipped)-1] ^= 1
	for name, try := range map[string]func() error{
		"flipped": func() error { _, err := openHPKEBody(sk, mustHex(t, fx.Info), mustHex(t, fx.AAD), flipped); return err },
		"aad":     func() error { _, err := openHPKEBody(sk, mustHex(t, fx.Info), []byte("Count-1"), body); return err },
		"info":    func() error { _, err := openHPKEBody(sk, []byte("other"), mustHex(t, fx.AAD), body); return err },
		"short": func() error {
			_, err := openHPKEBody(sk, mustHex(t, fx.Info), mustHex(t, fx.AAD), body[:40])
			return err
		},
	} {
		if err := try(); !errors.Is(err, ErrAuthenticationFailed) {
			t.Errorf("%s: %v, want ErrAuthenticationFailed", name, err)
		}
	}
	// Our seal opens under the same suite.
	sealed, err := sealHPKEBody(sk.PublicKey(), []byte("info"), []byte("aad"), []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := openHPKEBody(sk, []byte("info"), []byte("aad"), sealed); err != nil || string(got) != "hello" {
		t.Errorf("round trip: %q, %v", got, err)
	}
	p256, err := ecdh.P256().GenerateKey(rand.Reader)
	if err == nil {
		if _, err := sealHPKEBody(p256.PublicKey(), nil, nil, nil); err == nil {
			t.Error("a P-256 recipient was accepted")
		}
	}
}

type hpkeCase struct {
	Envelope string `json:"envelope"`
	Zone     string `json:"zone"`
	WireName string `json:"wireName"`
	Info     string `json:"info"`
	Kind     string `json:"kind"`
	ID       string `json:"id"`
	Payload  string `json:"payload"`
}

func TestKitVectors_HelloAndKeyboxOpen(t *testing.T) {
	var fx struct {
		Hello  hpkeCase `json:"hello"`
		Keybox hpkeCase `json:"keybox"`
	}
	loadFixture(t, "hpke-envelope.json", &fx)
	k := fixtureKeys(t)
	hubSigPub := k.hubSig.Public().(ed25519.PublicKey)
	devSigPub := k.devSig.Public().(ed25519.PublicKey)

	check := func(t *testing.T, h Header, f InnerFrame, c hpkeCase, sender ID) {
		t.Helper()
		if f.Kind != c.Kind || f.ID != c.ID || hex.EncodeToString(f.Payload) != c.Payload || f.NotifyLevel != "" || f.Asset != nil {
			t.Errorf("frame %+v disagrees with the fixture", f)
		}
		if h.Hub != fixtureHubID || h.Sender != sender || h.Epoch != 1 || h.Seq != 7 || h.Nonce != [12]byte{} {
			t.Errorf("header %+v", h)
		}
		if h.Flags != FlagSigned|FlagPadded {
			t.Errorf("flags %d", h.Flags)
		}
	}

	t.Run("hello", func(t *testing.T) {
		c := fx.Hello
		info := HelloInfo(fixtureHubID, linkNonce)
		if hex.EncodeToString(info) != c.Info || c.Zone != "RelayZone" {
			t.Fatalf("hello info %x, fixture %s", info, c.Info)
		}
		raw := mustHex(t, c.Envelope)
		ctx := Context{Zone: ZoneRelay, WireName: c.WireName}
		h, f, err := OpenHPKE(raw, ClassHello, k.hubKX, info, ctx, nil)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		check(t, h, f, c, k.deviceID)
		e, err := parseEnvelope(raw)
		if err != nil {
			t.Fatal(err)
		}
		if err := verify(e, ctx, devSigPub); err != nil {
			t.Errorf("dev_sig: %v", err)
		}
		if _, _, err := OpenHPKE(raw, ClassHello, k.hubKX, info, ctx, devSigPub); err != nil {
			t.Errorf("open with dev_sig verifier: %v", err)
		}
		moved := Context{Zone: ZoneRelay, WireName: "hello-00000000-0000-0000-0000-000000000000"}
		if _, _, err := OpenHPKE(raw, ClassHello, k.hubKX, info, moved, nil); !errors.Is(err, ErrAuthenticationFailed) {
			t.Errorf("moved wire name: %v", err)
		}
		if _, _, err := OpenHPKE(raw, ClassHello, k.hubKX, HelloInfo(fixtureHubID, metaKey), ctx, nil); !errors.Is(err, ErrAuthenticationFailed) {
			t.Errorf("another code's nonce: %v", err)
		}
		if _, _, err := OpenHPKE(raw, ClassKeybox, k.hubKX, info, ctx, hubSigPub); !errors.Is(err, ErrWrongClass) {
			t.Errorf("as keybox: %v", err)
		}
	})

	t.Run("keybox", func(t *testing.T) {
		c := fx.Keybox
		info := KeyboxInfo(fixtureHubID, k.deviceID)
		if hex.EncodeToString(info) != c.Info || c.Zone != "DataZone" {
			t.Fatalf("keybox info %x, fixture %s", info, c.Info)
		}
		if c.WireName != "keybox-"+k.deviceID.String() || c.ID != "device_grant-"+k.deviceID.String() || c.Kind != "device_grant" {
			t.Fatalf("keybox naming %s / %s / %s", c.WireName, c.ID, c.Kind)
		}
		raw := mustHex(t, c.Envelope)
		ctx := Context{Zone: ZoneData, WireName: c.WireName}
		h, f, err := OpenHPKE(raw, ClassKeybox, k.devKX, info, ctx, hubSigPub)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		check(t, h, f, c, fixtureHubID)
		for name, want := range map[string]struct {
			recipient *ecdh.PrivateKey
			verifier  ed25519.PublicKey
			ctx       Context
			err       error
		}{
			"no verifier":    {k.devKX, nil, ctx, ErrSignatureRequired},
			"dev_sig":        {k.devKX, devSigPub, ctx, ErrSignatureInvalid},
			"hub_kx":         {k.hubKX, hubSigPub, ctx, ErrAuthenticationFailed},
			"moved wire":     {k.devKX, hubSigPub, Context{Zone: ZoneData, WireName: "keybox-x"}, ErrSignatureInvalid},
			"moved zone":     {k.devKX, hubSigPub, Context{Zone: ZoneRelay, WireName: c.WireName}, ErrSignatureInvalid},
			"no recipient":   {nil, hubSigPub, ctx, ErrAuthenticationFailed},
			"verifier short": {k.devKX, hubSigPub[:31], ctx, ErrSignatureInvalid},
		} {
			if _, _, err := OpenHPKE(raw, ClassKeybox, want.recipient, info, want.ctx, want.verifier); !errors.Is(err, want.err) {
				t.Errorf("%s: %v, want %v", name, err, want.err)
			}
		}
		unsigned := bytes.Clone(raw[:len(raw)-64])
		unsigned[5] &^= FlagSigned
		if _, _, err := OpenHPKE(unsigned, ClassKeybox, k.devKX, info, ctx, hubSigPub); !errors.Is(err, ErrSignatureMissing) {
			t.Errorf("unsigned: %v", err)
		}
	})
}

func TestSealHPKE_RoundTripAndRules(t *testing.T) {
	k := fixtureKeys(t)
	hubSigPub := k.hubSig.Public().(ed25519.PublicKey)
	ctx := Context{Zone: ZoneData, WireName: "keybox-" + k.deviceID.String()}
	info := KeyboxInfo(fixtureHubID, k.deviceID)
	f := InnerFrame{Kind: "device_grant", ID: "device_grant-" + k.deviceID.String(), Payload: []byte(`{"grant":{}}`)}

	raw, err := SealHPKE(f, ClassKeybox, k.devKX.PublicKey(), info, fixtureHubID, fixtureHubID, 3, 9, ctx, k.hubSig)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != HeaderLen+32+256+16+64 {
		t.Errorf("sealed %d bytes, want the 256 bucket", len(raw))
	}
	h, got, err := OpenHPKE(raw, ClassKeybox, k.devKX, info, ctx, hubSigPub)
	if err != nil {
		t.Fatal(err)
	}
	if got.Kind != f.Kind || got.ID != f.ID || !bytes.Equal(got.Payload, f.Payload) || h.Epoch != 3 || h.Seq != 9 || h.Nonce != [12]byte{} {
		t.Errorf("round trip: %+v %+v", h, got)
	}
	if _, err := SealHPKE(f, ClassData, k.devKX.PublicKey(), info, fixtureHubID, fixtureHubID, 1, 1, ctx, k.hubSig); !errors.Is(err, ErrWrongClass) {
		t.Errorf("data class: %v", err)
	}
	if _, err := SealHPKE(f, ClassKeybox, k.devKX.PublicKey(), info, fixtureHubID, fixtureHubID, 1, 1, ctx, nil); !errors.Is(err, ErrSignatureRequired) {
		t.Errorf("no signer: %v", err)
	}
	big := f
	big.Payload = make([]byte, FrameCap(true)-32)
	if _, err := SealHPKE(big, ClassKeybox, k.devKX.PublicKey(), info, fixtureHubID, fixtureHubID, 1, 1, ctx, k.hubSig); !errors.Is(err, ErrOversized) {
		t.Errorf("oversized: %v", err)
	}
	fits := f
	fits.Payload = make([]byte, FrameCap(true)-32-(f.EncodedLength()-len(f.Payload)))
	maxed, err := SealHPKE(fits, ClassKeybox, k.devKX.PublicKey(), info, fixtureHubID, fixtureHubID, 1, 1, ctx, k.hubSig)
	if err != nil || len(maxed) != MaxEnvelopeBytes {
		t.Errorf("largest keybox: %d bytes, %v", len(maxed), err)
	}
}
