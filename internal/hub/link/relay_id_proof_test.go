package link

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// newRelayKey is a phone's relay_auth key (its own key, not its signing key).
func newRelayKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, k, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// signRelayID fills p's relay id fields as the phone does: the id of key,
// key's public half and key's signature over the proof message for hub and
// device.
func signRelayID(p *wire.DevicePayload, key ed25519.PrivateKey, hub, device secure.ID) {
	pub := key.Public().(ed25519.PublicKey)
	p.RelayDeviceID = identity.RelayDeviceID(pub)
	p.RelayAuthPub = b64.EncodeToString(pub)
	p.RelayIDSig = b64.EncodeToString(ed25519.Sign(key, RelayIDProofMessage(hub, device, p.RelayDeviceID)))
}

func TestRelayIDProofMessageLayout(t *testing.T) {
	hub, device := secure.ID{1, 2, 3}, secure.ID{4, 5, 6}
	id := identity.RelayDeviceID(newRelayKey(t).Public().(ed25519.PublicKey))
	got := RelayIDProofMessage(hub, device, id)
	want := append([]byte("watchtower/v1/relay-id\x00"), hub[:]...)
	want = append(want, device[:]...)
	want = append(want, id...)
	if !bytes.Equal(got, want) || len(got) != len("watchtower/v1/relay-id")+1+16+16+52 {
		t.Fatalf("message %x, want %x", got, want)
	}
}

func TestVerifyRelayIDProof(t *testing.T) {
	hub, device := secure.ID{0xAA, 1}, secure.ID{0xBB, 2}
	key, other := newRelayKey(t), newRelayKey(t)
	proven := func() wire.DevicePayload {
		var p wire.DevicePayload
		signRelayID(&p, key, hub, device)
		return p
	}
	good := proven()
	if id, ok := VerifyRelayIDProof(hub, device, good); !ok || id != good.RelayDeviceID {
		t.Fatalf("a proven id: %q %v", id, ok)
	}
	cases := map[string]func(*wire.DevicePayload){
		"no id":       func(p *wire.DevicePayload) { p.RelayDeviceID = "" },
		"no key":      func(p *wire.DevicePayload) { p.RelayAuthPub = "" },
		"no sig":      func(p *wire.DevicePayload) { p.RelayIDSig = "" },
		"invalid id":  func(p *wire.DevicePayload) { p.RelayDeviceID = "CCCCCCCC-0000-4000-8000-000000000003" },
		"short key":   func(p *wire.DevicePayload) { p.RelayAuthPub = b64.EncodeToString(make([]byte, 31)) },
		"padded key":  func(p *wire.DevicePayload) { p.RelayAuthPub += "=" },
		"short sig":   func(p *wire.DevicePayload) { p.RelayIDSig = b64.EncodeToString(make([]byte, 63)) },
		"wrong key":   func(p *wire.DevicePayload) { signRelayID(p, other, hub, device); p.RelayDeviceID = good.RelayDeviceID },
		"bad sig":     func(p *wire.DevicePayload) { p.RelayIDSig = b64.EncodeToString(make([]byte, 64)) },
		"other hub":   func(p *wire.DevicePayload) { signRelayID(p, key, secure.ID{0xCC}, device) },
		"other phone": func(p *wire.DevicePayload) { signRelayID(p, key, hub, secure.ID{0xDD}) },
	}
	for name, edit := range cases {
		p := proven()
		edit(&p)
		if id, ok := VerifyRelayIDProof(hub, device, p); ok || id != "" {
			t.Errorf("%s: accepted %q", name, id)
		}
	}
}
