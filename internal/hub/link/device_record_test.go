package link

import (
	"context"
	"crypto/ed25519"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// linkPhone links a new phone over a hello with no relay id (an iCloud
// link's), edited by edit.
func (r *rig) linkPhone(edit ...func(*wire.DeviceHello)) phone {
	r.t.Helper()
	p := newPhone(r.t)
	r.handle(p, r.issue().Nonce, edit...)
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		r.t.Fatalf("Confirm: %v", err)
	}
	return p
}

// relayIDOf is p's stored relay id and whether its admission stamp is set.
func (r *rig) relayIDOf(p phone) (id string, admitted bool) {
	r.t.Helper()
	d, ok, err := r.st.Device(p.id.String())
	if err != nil || !ok {
		r.t.Fatalf("device %v %v", ok, err)
	}
	return d.RelayDeviceID, !d.RelayAdmittedAt.IsZero()
}

// provenBy is a device record edit naming key's relay id, signed by key for
// this hub and p.
func (r *rig) provenBy(p phone, key ed25519.PrivateKey) func(*wire.DevicePayload) {
	return func(d *wire.DevicePayload) { signRelayID(d, key, r.kr.HubID(), p.id) }
}

func TestADeviceRecordWithAProofGivesAnICloudLinkItsRelayID(t *testing.T) {
	r := newRig(t)
	p := r.linkPhone()
	if id, _ := r.relayIDOf(p); id != "" {
		t.Fatalf("an iCloud link has a relay id: %q", id)
	}
	key := newRelayKey(t)
	named := 0
	r.c.OnRelayIDNamed(func(device string) {
		if device == strings.ToUpper(p.id.String()) {
			named++
		}
	})
	r.rewriteRecord(p, r.provenBy(p, key))
	want := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	if id, admitted := r.relayIDOf(p); id != want || admitted {
		t.Fatalf("relay id %q admitted %v, want %q not admitted", id, admitted, want)
	}
	if named != 1 {
		t.Fatalf("the relay id seam ran %d times", named)
	}
	if _, err := r.st.MarkRelayAdmitted([]string{want}, r.clock()); err != nil {
		t.Fatal(err)
	}
	// The same record again names nothing new: the stamp stays.
	r.rewriteRecord(p, r.provenBy(p, key))
	if id, admitted := r.relayIDOf(p); id != want || !admitted || named != 1 {
		t.Fatalf("a repeat: id %q admitted %v named %d", id, admitted, named)
	}
	// A new proven id replaces it and clears the stamp, so the stamp
	// follows the account again.
	key2 := newRelayKey(t)
	r.rewriteRecord(p, r.provenBy(p, key2))
	if id, admitted := r.relayIDOf(p); id != identity.RelayDeviceID(key2.Public().(ed25519.PublicKey)) || admitted || named != 2 {
		t.Fatalf("a new id: %q admitted %v named %d", id, admitted, named)
	}
}

func TestAnUnprovenRelayIDIsIgnored(t *testing.T) {
	key, other := newRelayKey(t), newRelayKey(t)
	cases := map[string]func(r *rig, p phone) func(*wire.DevicePayload){
		"no key": func(r *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) { r.provenBy(p, key)(d); d.RelayAuthPub, d.RelayIDSig = "", "" }
		},
		"a key that is not the id's": func(r *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) {
				id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
				r.provenBy(p, other)(d)
				d.RelayDeviceID = id
			}
		},
		"a bad signature": func(r *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) {
				r.provenBy(p, key)(d)
				d.RelayIDSig = b64.EncodeToString(ed25519.Sign(other, []byte("x")))
			}
		},
		"signed for another hub": func(_ *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) { signRelayID(d, key, secure.ID{0xEE}, p.id) }
		},
		"signed for another device": func(r *rig, _ phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) { signRelayID(d, key, r.kr.HubID(), secure.ID{0xEE}) }
		},
		"an invalid id": func(r *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) { r.provenBy(p, key)(d); d.RelayDeviceID = strings.ToUpper(d.RelayDeviceID) }
		},
	}
	for name, edit := range cases {
		t.Run(name, func(t *testing.T) {
			r := newRig(t)
			p := r.linkPhone()
			claim := edit(r, p)
			r.rewriteRecord(p, func(d *wire.DevicePayload) { claim(d); d.Name = "Renamed" })
			if id, _ := r.relayIDOf(p); id != "" {
				t.Fatalf("stored %q", id)
			}
			if d, _, _ := r.st.Device(p.id.String()); d.Name != "Renamed" {
				t.Fatalf("the rest of the record was not applied: name %q", d.Name)
			}
		})
	}
}

func TestAPhoneCannotClaimAPayingPhonesRelayID(t *testing.T) {
	r := newRig(t)
	aKey := newRelayKey(t)
	aID := identity.RelayDeviceID(aKey.Public().(ed25519.PublicKey))
	a := r.linkPhone(withRelayID(aID)) // a relay link, the paying phone
	b := r.linkPhone()
	bKey := newRelayKey(t)

	// B names A's id with its own key: the key is not the id's.
	r.rewriteRecord(b, func(d *wire.DevicePayload) { r.provenBy(b, bKey)(d); d.RelayDeviceID = aID })
	if id, _ := r.relayIDOf(b); id != "" {
		t.Fatalf("B took A's id with its own key: %q", id)
	}
	// B names A's id with A's public key but cannot sign with it.
	r.rewriteRecord(b, func(d *wire.DevicePayload) {
		r.provenBy(b, bKey)(d)
		d.RelayDeviceID, d.RelayAuthPub = aID, b64.EncodeToString(aKey.Public().(ed25519.PublicKey))
	})
	if id, _ := r.relayIDOf(b); id != "" {
		t.Fatalf("B took A's id with A's key and its own signature: %q", id)
	}
	if id, _ := r.relayIDOf(a); id != aID {
		t.Fatalf("A's id changed: %q", id)
	}
}

func TestARelayIDAnotherPhoneHoldsIsRefused(t *testing.T) {
	r := newRig(t)
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	a := r.linkPhone(withRelayID(id))
	b := r.linkPhone()
	// Even a valid proof for B (the key's holder signed it) cannot take an
	// id A holds: one relay id names one phone.
	r.rewriteRecord(b, r.provenBy(b, key))
	if got, _ := r.relayIDOf(b); got != "" {
		t.Fatalf("B holds %q too", got)
	}
	if got, _ := r.relayIDOf(a); got != id {
		t.Fatalf("A's id changed: %q", got)
	}
}

func TestADeviceRecordFromAnotherWriterNamesNoRelayID(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a")
	p := newPhone(t)
	r.linkCK(p, code.Nonce, sharedHello("_colleague-a"))
	d := wire.DevicePayload{DeviceID: p.id.String(), Name: "iPhone", Scope: wire.ScopeShared,
		UserRecordName: "_colleague-a", StartSessions: true, UpdatedAt: wire.Time{Time: r.clock()}}
	r.provenBy(p, newRelayKey(t))(&d)
	if err := r.c.ApplyDeviceRecord(r.ctx, p.id.String(), DeviceRecord{Payload: d, Creator: "_colleague-b", Shares: r.s}); err != nil {
		t.Fatal(err)
	}
	if id, _ := r.relayIDOf(p); id != "" {
		t.Fatalf("a record another user wrote named %q", id)
	}
	// Written by the phone's own user, the same record names it.
	if err := r.c.ApplyDeviceRecord(r.ctx, p.id.String(), DeviceRecord{Payload: d, Creator: "_colleague-a", Shares: r.s}); err != nil {
		t.Fatal(err)
	}
	if id, _ := r.relayIDOf(p); id != d.RelayDeviceID {
		t.Fatalf("the phone's own record: %q", id)
	}
}

func TestTheUpgradedPhoneIsAReaderAfterItsRecord(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	relayLinked := relayID(t)
	r.linkPhone(withRelayID(relayLinked))
	p := r.linkPhone()
	var rd readers
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	if got := rd.last(t); !slices.Equal(got, []string{relayLinked}) {
		t.Fatalf("readers before the record: %v", got)
	}
	key := newRelayKey(t)
	r.rewriteRecord(p, r.provenBy(p, key))
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	want := []string{relayLinked, identity.RelayDeviceID(key.Public().(ed25519.PublicKey))}
	slices.Sort(want)
	if got := rd.last(t); !slices.Equal(got, want) {
		t.Fatalf("readers after the record: %v, want %v", got, want)
	}
}

func TestFILES01_DeviceRecordRelayIDLogsNoNames(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t)
	name := logcanary.Text("device.name")
	p := r.linkPhone()
	key := newRelayKey(t)
	r.rewriteRecord(p, func(d *wire.DevicePayload) { r.provenBy(p, key)(d); d.Name = name })
	r.rewriteRecord(p, func(d *wire.DevicePayload) {
		r.provenBy(p, newRelayKey(t))(d)
		d.RelayIDSig = b64.EncodeToString(make([]byte, 64))
		d.Name = name
	})
	sink.AssertClean(t)
	out := sink.String()
	if !strings.Contains(out, "named its relay id") || !strings.Contains(out, "bad_signature") {
		t.Fatalf("the relay id lines are missing: %s", out)
	}
	pub := b64.EncodeToString(key.Public().(ed25519.PublicKey))
	if strings.Contains(out, pub) || strings.Contains(out, identity.RelayDeviceID(key.Public().(ed25519.PublicKey))) {
		t.Error("a relay key or id reached the log")
	}
}
