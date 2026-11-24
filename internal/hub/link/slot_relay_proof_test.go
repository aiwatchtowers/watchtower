package link

import (
	"context"
	"crypto/ed25519"
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// withRelayProof is an upgraded phone's slot hello (#2387): its device data
// carries key's relay id, key and key's signature for hub and p, and the
// hello names that id.
func withRelayProof(key ed25519.PrivateKey, hub secure.ID, p phone) func(*wire.DeviceHello) {
	return func(h *wire.DeviceHello) {
		signRelayID(&h.Device, key, hub, p.id)
		h.RelayDeviceID = h.Device.RelayDeviceID
	}
}

// relayIDOf is key's relay id.
func relayIDOf(key ed25519.PrivateKey) string {
	return identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
}

// slotHello is p's hello under code read from the named pairing slot (a fresh
// fake: each call names its own slot), and its sas
// event (the request waits).
func (r *rig) slotHello(slot string, p phone, nonce string, edit ...func(*wire.DeviceHello)) PairEvent {
	r.t.Helper()
	f := memfake.New(transport.KindRelay, r.clock)
	r.writeHello(f, slot, p, nonce, edit...)
	if err := r.c.OnPairingOpened(context.Background(), f, slot); err != nil {
		r.t.Fatal(err)
	}
	return sasEvent(r.t, r.c)
}

// #2387: a slot hello marks the phone as linked over Relay (the switcher's
// relay-link candidate, the sas line's move to Relay) only when its device
// data proves the relay id the hello names. Any other slot hello still waits
// and links, with its relay id kept as an unproven claim, as a CloudKit
// hello would: an older phone links, just without the Relay switch.
func TestASlotHelloIsARelayLinkOnlyWithItsRelayIDProven(t *testing.T) {
	cases := []struct {
		name   string
		edit   func(r *rig, p phone) func(*wire.DeviceHello)
		marked bool
	}{
		{"valid proof", func(r *rig, p phone) func(*wire.DeviceHello) {
			return withRelayProof(newRelayKey(t), r.kr.HubID(), p)
		}, true},
		{"no proof (an older phone)", func(*rig, phone) func(*wire.DeviceHello) {
			return withRelayID(relayID(t))
		}, false},
		{"a proof of another id", func(r *rig, p phone) func(*wire.DeviceHello) {
			proof := withRelayProof(newRelayKey(t), r.kr.HubID(), p)
			other := relayID(t)
			return func(h *wire.DeviceHello) { proof(h); h.RelayDeviceID = other }
		}, false},
		{"a proof for another hub", func(_ *rig, p phone) func(*wire.DeviceHello) {
			return withRelayProof(newRelayKey(t), newPhone(t).id, p)
		}, false},
		{"a proof for another phone", func(r *rig, _ phone) func(*wire.DeviceHello) {
			return withRelayProof(newRelayKey(t), r.kr.HubID(), newPhone(t))
		}, false},
		{"a bad signature", func(r *rig, p phone) func(*wire.DeviceHello) {
			proof := withRelayProof(newRelayKey(t), r.kr.HubID(), p)
			return func(h *wire.DeviceHello) {
				proof(h)
				h.Device.RelayIDSig = b64.EncodeToString(make([]byte, ed25519.SignatureSize))
			}
		}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(t)
			code := r.issue()
			p := newPhone(t)
			var named string
			edit := tc.edit(r, p)
			ev := r.slotHello("slot1", p, code.Nonce, edit, func(h *wire.DeviceHello) { named = h.RelayDeviceID })
			if ev.OverRelay != tc.marked || ev.Code == "" {
				t.Fatalf("sas: %+v, want OverRelay %v", ev, tc.marked)
			}
			if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
				t.Fatal(err)
			}
			r.wantSlotLinked(p, tc.marked)
			d, ok, err := r.st.Device(p.id.String())
			if err != nil || !ok || d.RelayDeviceID != named {
				t.Fatalf("device row %+v %v %v: the hello's relay id %q is kept either way", d, ok, err, named)
			}
		})
	}
}

// #2387: the same phone's hello re-sent with a proof is a change of route
// (a new request, now marked); re-sent unchanged without one draws nothing
// and stays unmarked.
func TestASlotHelloGainingAProofReplacesItsRequest(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	p := newPhone(t)
	key := newRelayKey(t)
	claim := withRelayID(relayIDOf(key))
	if ev := r.slotHello("slot1", p, code.Nonce, claim); ev.OverRelay {
		t.Fatalf("an unproven slot hello's sas: %+v", ev)
	}
	again, err := r.c.HandleHello(transport.PairZone("slot1"), p.name(), r.hello(p, code.Nonce, claim))
	if err != nil || again.Code == "" {
		t.Fatalf("unchanged re-send: %+v %v", again, err)
	}
	select {
	case ev := <-r.c.Events():
		t.Fatalf("an unchanged re-send emitted %+v", ev)
	default:
	}
	if ev := r.slotHello("slot2", p, code.Nonce, withRelayProof(key, r.kr.HubID(), p)); !ev.OverRelay {
		t.Fatalf("the proven re-send's sas: %+v", ev)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		t.Fatal(err)
	}
	r.wantSlotLinked(p, true)
}
